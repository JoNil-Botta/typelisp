;; Lease-checked selected occurrences -> owned primitive ownership CFG (#8449).
;; This module never queries source ASTs or re-runs inference. Primitive type
;; codes remain distinct in the core table even though their ownership class is
;; uniformly Copy. Unsupported representations never produce a certificate.
(import compiler_ast_types as ast)
(import compiler_typed_occurrence as typed)
(import compiler_ownership_core as own)
(cfg ownership-mir-dump (import compiler_ownership_dump as ownership_dump))
(cfg ownership-mir-dump (import stdlib.io))
(import stdlib.string)

(defstruct OwnershipNormalizeLimits
  (records i64)
  (depth i64)
  (work i64)
  (source-bytes i64)
  (core own.OwnershipLimits))

(define (ownership-normalize-default-limits) : OwnershipNormalizeLimits
  (OwnershipNormalizeLimits
    1048576
    ;; Nesting depth of the walk's recursion: a `cond` or generated table of N
    ;; arms nests N `if`s. The compiler runs on the runtime's 1 GiB main stack
    ;; (it spawns no worker threads), so 4096 levels leave a wide margin.
    4096
    33554432
    ;; Every node and place carries its own copy of its source path and
    ;; expansion, so provenance bytes grow with the body's records times its
    ;; path length (4 MiB stopped 500-branch bodies). A lowered program's
    ;; bodies also share one 64 MiB retained-bytes budget
    ;; (`tc-selected-prepare-named-in-scratch`).
    67108864
    (own.ownership-default-limits)))

(defenum NormalizeCoreLimit
  (Resource)
  (Unsupported)
  (No))

(define (normalize-core-limit [failure : (& failure own.OwnershipFailure)]) : NormalizeCoreLimit
  (match (& failure.kind)
    [(own.OwnershipFailureKind.Resource) NormalizeCoreLimit.Resource]
    [(own.OwnershipFailureKind.Unsupported) NormalizeCoreLimit.Unsupported]
    [_ NormalizeCoreLimit.No]))

;; A core rejection explained in source terms: the binder whose value was
;; read after a move, and the move that left it empty. The explanation never
;; changes the verdict; the core failure stays authoritative.
(defstruct OwnershipMoveDiagnostic
  (name i64)
  ;; Field name ids from the binder to the failing place (see the product names).
  (fields (__tl_dyn-array i64))
  (loop-carried? bool)
  (move own.OwnershipSource)
  ;; Field name ids from the binder to the place the move took: a part of the
  ;; used place when only that part moved (`p.inner.handle` for `p.inner`).
  (moved-fields (__tl_dyn-array i64)))

;; A non-Copy value taken out of a part the checker cannot name or does not
;; own: a dynamic-array element (kind 0) or a place behind a shared (kind 1)
;; or mutable (kind 2) reference. Only `replace!` may move such a part out; a
;; borrow or a Copy part reads it in place.
(defstruct OwnershipMoveOutDiagnostic
  (name i64)
  (fields (__tl_dyn-array i64))
  (kind i64)
  (source own.OwnershipSource)
  ;; The moved value's type, and what consumes it (`move-context`: 1 a `let`
  ;; initializer, 2 a call argument, 3 a constructor argument, 4 a returned
  ;; value, 0 another use), for the diagnostic's wording.
  (type NormalizeMaybeType)
  (context i64))

(defenum NormalizeMaybeType
  (Some typed.TypedTypeId)
  (No))

;; A broken cleanup or `:invalidate` obligation (SPEC 4.7.1, 5.19, 5.16), in
;; source terms: the owner
;; binder; what was found (0 not discharged, 1 discharged on only some paths,
;; 2 lost to a move that does not discharge it, 3 only partly discharged, 4 a
;; `with` owner moved out); the exit (0 the end of its `let` scope, 1 a
;; return, 2 a break, 3 a continue, 4 a `try` propagation, -1 none) and the
;; exit's or the losing move's source. A `with` owner moved out (4) also
;; carries the move that emptied it and the owner's binding.
(defstruct OwnershipObligationDiagnostic
  (name i64)
  (status i64)
  (exit i64)
  (source own.OwnershipSource)
  ;; An `:invalidate` parameter's lifetime (its brand obligation, exit 5 the
  ;; end of its function), or -1 for a cleanup obligation.
  (lifetime i64)
  ;; At an atomic arena's release (exit 6: the owner, `name`, has thread
  ;; users; exit 7: thread handle `name` is live), the arena owner's name;
  ;; -1 otherwise.
  (arena i64)
  (move NormalizeMoveDiagnosticResult)
  (bound own.OwnershipSource))

;; An access that conflicts with a live loan, in source terms: the binder, the
;; kind of access (0 assign, 1 move, 2 mutable borrow, 3 shared borrow of a
;; mutably borrowed place, 4 read) and the conflicting loan's borrow site.
(defstruct OwnershipBorrowDiagnostic
  (name i64)
  (fields (__tl_dyn-array i64))
  ;; 0 assign, 1 move, 2 mutable borrow, 3 shared borrow, 4 read, 5 mutable
  ;; borrow through a shared reference, 6 a call that may assign the global
  ;; (`callee` and `global` name the effect-graph nodes, else -1).
  (access i64)
  (borrow own.OwnershipSource)
  (callee i64)
  (global i64))

(defenum OwnershipNormalizeFailure
  (Typed typed.TypedError)
  (Structural String)
  (Unsupported String)
  (Resource)
  (Core own.OwnershipFailure)
  (Moved own.OwnershipFailure OwnershipMoveDiagnostic)
  (Borrowed own.OwnershipFailure OwnershipBorrowDiagnostic)
  (MoveOut OwnershipMoveOutDiagnostic)
  (Obligation OwnershipObligationDiagnostic))

(defenum OwnershipNormalizeResult
  (Ok OwnershipNormalizedBody)
  (Err OwnershipNormalizeFailure))

(defenum NormalizeUnit
  (Ok unit)
  (Err OwnershipNormalizeFailure))

(defenum NormalizeInt
  (Ok i64)
  (Err OwnershipNormalizeFailure))

(defenum NormalizeWords
  (Ok (__tl_dyn-array i64))
  (Err OwnershipNormalizeFailure))

(defenum NormalizeSource
  (Ok own.OwnershipSource)
  (Err OwnershipNormalizeFailure))

;; Unit, Bool, I8/I16/I32/I64, U8/U16/U32/U64, F32/F64, Char, Never.
;; Never (13) denotes an exit and never receives a storage place.
(define (normalize-type-code [ty : (& ty ast.AstType)]) : NormalizeInt
  (match ty
    [(ast.AstType.Unit) (NormalizeInt.Ok 0)]
    [(ast.AstType.Bool) (NormalizeInt.Ok 1)]
    [(ast.AstType.I8) (NormalizeInt.Ok 2)]
    [(ast.AstType.I16) (NormalizeInt.Ok 3)]
    [(ast.AstType.I32) (NormalizeInt.Ok 4)]
    [(ast.AstType.I64) (NormalizeInt.Ok 5)]
    [(ast.AstType.U8) (NormalizeInt.Ok 6)]
    [(ast.AstType.U16) (NormalizeInt.Ok 7)]
    [(ast.AstType.U32) (NormalizeInt.Ok 8)]
    [(ast.AstType.U64) (NormalizeInt.Ok 9)]
    [(ast.AstType.F32) (NormalizeInt.Ok 10)]
    [(ast.AstType.F64) (NormalizeInt.Ok 11)]
    [(ast.AstType.Char) (NormalizeInt.Ok 12)]
    [(ast.AstType.Never) (NormalizeInt.Ok 13)]
    ;; A region tag on a primitive (read through a reference) is dropped, as
    ;; the graph drops one on any Copy value (`tc-selected-canonical-type`).
    [(ast.AstType.Region _ inner)
      (normalize-type-code (& (ast.ty-node-get inner)))]
    [_
      (NormalizeInt.Err
        (OwnershipNormalizeFailure.Unsupported
          "ownership normalization: nonprimitive canonical type"))]))

;; The typechecker's ownership class for one typed type record, indexed by the
;; record's handle index. Records whose canonical types are equal share `key`.
;; A negative key keeps the type outside the normalized subset: references,
;; regions, cleanup owners, arena authorities and unresolved types retain
;; their dedicated checks until the core models them.
(defstruct OwnershipNormalizeTypeClass
  (key i64)
  (copy? bool)
  ;; 0 for a value, 1 for a shared reference, 2 for a mutable reference. A
  ;; reference's referent carries no further reference or special owner.
  (reference i64)
  ;; The referent's typed type index for a reference or a view, or the
  ;; contents of an owned box (reference 0); otherwise -1.
  (referent i64)
  ;; A value owning a cleanup obligation somewhere in it (SPEC 4.7.1):
  ;; overwriting it while initialized would lose that cleanup.
  (cleanup? bool))

;; The shape of a struct or tuple class, indexed by class key: each field's
;; typed type index in ordinal order and its source name id (a tuple
;; element's is -1 - ordinal). Classes without a shape have no fields.
(defstruct OwnershipNormalizeProduct
  (fields (__tl_dyn-array i64))
  (names (__tl_dyn-array i64)))

;; The declared variance of struct and enum lifetime parameters, from typing
;; (`tc-nominal-lifetime-variance-at`): nominal `names[i]`'s parameter `k` is
;; covariant when `covariant[starts[i] + k]` holds, for `k` below
;; `counts[i]`. Region nodes relate a nominal type's lifetime arguments by
;; that variance, as Rust's do; a nominal or parameter missing here relates
;; invariantly.
(defstruct OwnershipNormalizeVariances
  (names (__tl_dyn-array i64))
  (starts (__tl_dyn-array i64))
  (counts (__tl_dyn-array i64))
  (covariant (__tl_dyn-array bool)))

(define (ownership-normalize-variances-empty) : OwnershipNormalizeVariances
  (OwnershipNormalizeVariances
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array bool 0)))

;; The globals the body's calls may assign (#7904), from typing's global
;; effect graph: typed call record `calls[i]` may assign the module value
;; whose typed binder record is `binders[i]`, reached from callee node
;; `callees[i]` (global node `globals[i]`). The call assigns that global's
;; place after its operands, so a loan of it still live there conflicts.
;; Likewise the declared cleanup of the type with class key `cleanup-keys[j]`
;; may assign the global of binder `cleanup-binders[j]`: a temporary of that
;; type borrowed for a call is disposed of when the call returns. An entry
;; whose effect is still unknown (`pending?`: no path yet, while bodies typed
;; later may still add inferred cleanup edges) is probed instead of assigned:
;; the body reports whether a loan of that global is live there
;; (`OwnershipNormalizeDeferred`), and typing asks the graph again at the end.
(defstruct OwnershipNormalizeGlobalWrites
  (calls (__tl_dyn-array i64))
  (binders (__tl_dyn-array i64))
  (callees (__tl_dyn-array i64))
  (globals (__tl_dyn-array i64))
  (pending? (__tl_dyn-array bool))
  (cleanup-keys (__tl_dyn-array i64))
  (cleanup-binders (__tl_dyn-array i64))
  (cleanup-callees (__tl_dyn-array i64))
  (cleanup-globals (__tl_dyn-array i64))
  (cleanup-pending? (__tl_dyn-array bool))
  ;; The cleanup of `with` owner binder record `owners[k]` runs at each exit
  ;; of its scope and may assign the global of binder `owner-binders[k]`.
  (owners (__tl_dyn-array i64))
  (owner-binders (__tl_dyn-array i64))
  (owner-callees (__tl_dyn-array i64))
  (owner-globals (__tl_dyn-array i64))
  (owner-pending? (__tl_dyn-array bool)))

(define (ownership-normalize-global-writes-empty) : OwnershipNormalizeGlobalWrites
  (OwnershipNormalizeGlobalWrites
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array bool 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array bool 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array i64 0)
    (__tl_make-array bool 0)))

;; The probed calls (`OwnershipNormalizeGlobalWrites`) at which a loan of the
;; global is live: callee and global nodes, the global binder's name, the
;; call's source and the live loan's.
(defstruct OwnershipNormalizeDeferred
  (callees (__tl_dyn-array i64))
  (globals (__tl_dyn-array i64))
  (names (__tl_dyn-array i64))
  (calls (__tl_dyn-array own.OwnershipSource))
  (borrows (__tl_dyn-array own.OwnershipSource)))

;; Whether nominal `name`'s lifetime parameter `index` is declared covariant.
(define (normalize-nominal-covariant?
  [variances : (& variances OwnershipNormalizeVariances)]
  [name : i64]
  [index : i64]) : bool
  (let
    [at : i64 0]
    (while (< at (array-length variances.names))
      (when
        (= (array-ref variances.names at) name)
        (return
          (and
            (>= index 0)
            (< index (array-ref variances.counts at))
            (array-ref
              variances.covariant
              (+ (array-ref variances.starts at) index)))))
      (set! at (+ at 1)))
    false))

;; Body type indices: 0-12 are the primitive codes, 13 is reserved for Never
;; (an exit, never storage), and classified value types follow.
(define normalize-first-value-type : i64
  14)

(define (normalize-storage-type?
  [state : (& state NormalizeState)]
  [type : i64]) : bool
  (and (>= type 0) (!= type 13) (< type (array-length state.body.types))))

;; Any value type outside the primitive codes is a whole value: Copy values
;; copy and move-only values transfer and leave their source empty. A struct or
;; tuple class this body projects is a product of its field types, so a field
;; can move out on its own (a partial move) and its places are checked apart.
(define (normalize-value-type!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [index : i64]) : NormalizeInt
  (unless
    (and
      (>= index 0)
      (< index (array-length state.classes))
      (>= (array-ref state.classes index).key 0))
    (return
      (NormalizeInt.Err
        (OwnershipNormalizeFailure.Unsupported
          "ownership normalization: nonprimitive canonical type"))))
  (let
    [key : i64 (array-ref state.classes index).key]
    [copy? : bool (array-ref state.classes index).copy?]
    (while (<= (array-length state.class-types) key)
      (begin
        (try (normalize-charge! state 1 1 0))
        (__tl_array-push! state.class-types -1)))
    (when
      (< (array-ref state.class-types key) 0)
      (let
        [fields : (__tl_dyn-array own.OwnershipTypeId)
          (__tl_make-array own.OwnershipTypeId 0)]
        [product? : bool
          (and
            (< key (array-length state.projected))
            (array-ref state.projected key)
            (< key (array-length state.products))
            (> (array-length (array-ref state.products key).fields) 0))]
        [ordinal : i64 0]
        (when
          product?
          (while (<
            ordinal
            (array-length (array-ref state.products key).fields))
            (let
              [field : typed.TypedTypeId
                (match (typed.typed-type-at!
                  store
                  lease
                  (array-ref (array-ref state.products key).fields ordinal))
                  [(typed.TypedTypeIdResult.Ok id) id]
                  [(typed.TypedTypeIdResult.Err error)
                    (return
                      (NormalizeInt.Err (OwnershipNormalizeFailure.Typed error)))])]
              [type : i64 (try (normalize-type! state store lease field))]
              (try (normalize-charge! state 1 1 0))
              (__tl_array-push!
                fields
                (own.OwnershipTypeId
                  (typed.typed-body-copy (& state.body.id))
                  type))
              (set! ordinal (+ ordinal 1)))))
        (try (normalize-charge! state 1 1 0))
        (set! (array-ref state.class-types key) (array-length state.body.types))
        (__tl_array-push!
          state.body.types
          (own.OwnershipType
            (if product?
              (own.OwnershipTypeKind.Product (own.OwnershipTypeIds fields))
              own.OwnershipTypeKind.Scalar)
            copy?))
        (__tl_array-push! state.type-keys key)
        (while (<
          (array-length state.type-references)
          (array-length state.body.types))
          (__tl_array-push! state.type-references 0))
        (set!
          (array-ref
            state.type-references
            (- (array-length state.body.types) 1))
          (array-ref state.classes index).reference)
        (while (<
          (array-length state.type-cleanups)
          (array-length state.body.types))
          (__tl_array-push! state.type-cleanups false))
        (set!
          (array-ref state.type-cleanups (- (array-length state.body.types) 1))
          (array-ref state.classes index).cleanup?)))
    (NormalizeInt.Ok (array-ref state.class-types key))))

(define (normalize-type!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedTypeId]) : NormalizeInt
  (match (typed.typed-type-get! store lease id)
    [(typed.TypedTypeResult.Ok ty)
      (match (normalize-type-code ty)
        [(NormalizeInt.Ok code) (NormalizeInt.Ok code)]
        [(NormalizeInt.Err _)
          (normalize-value-type! state store lease id.handle.index)])]
    [(typed.TypedTypeResult.Err error)
      (NormalizeInt.Err (OwnershipNormalizeFailure.Typed error))]))

;; The field types of a product body type (empty for any other kind).
(define (normalize-product-fields
  [state : (& state NormalizeState)]
  [type : i64]) : (__tl_dyn-array i64)
  (let
    [fields : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (match (& (array-ref state.body.types type).kind)
      [(own.OwnershipTypeKind.Product items)
        (let
          [index : i64 0]
          (while (< index (array-length items.items))
            (begin
              (__tl_array-push! fields (array-ref items.items index).index)
              (set! index (+ index 1)))))]
      [_ unit])
    fields))

;; A product place is expanded lazily: its field places (one per field, in
;; ordinal order, each named by its source field) are created together the
;; first time a field of it is projected. An unexpanded product place is a leaf
;; for the core; most fields of large aggregates are never named.
;; Private dynamic buffers copy their whole backing on every push, so a body
;; with n places would allocate O(n^2) bytes. The normalizer's growing arrays
;; keep spare capacity instead: a count field holds the live prefix and the
;; backing doubles when full. Relocation moves the live elements bitwise; the
;; old backing is never read again. `normalize-trim!` cuts each array to its
;; live length before the body leaves the walk.
(defmacro (normalize-reserve!
  [cells : Expr]
  [count : Expr]
  ;; Spliced into the backing's element type.
  ;; lint-allow: unused-variable
  [item-ty : Expr]) : Expr
  `(when
    (>= ,count (array-length ,cells))
    (let
      [grown : (__tl_dyn-array ,item-ty)
        (__tl_make-array ,item-ty (+ 8 (* 2 ,count)))]
      [at : i64 0]
      (while (< at ,count)
        (set!
          (array-ref grown at)
          (unsafe
            (ptr-read (ptr-offset (__tl_array-data ,cells) at))))
        (set! at (+ at 1)))
      (set! ,cells grown))))

;; A growable column: `items` holds `len` cells and grows geometrically
;; (`__tl_array-push!` copies the whole array on every push).
(defstruct NormalizeI64s
  (items (__tl_dyn-array i64))
  (len i64))

(defstruct NormalizeBools
  (items (__tl_dyn-array bool))
  (len i64))

(define (normalize-i64s) : NormalizeI64s
  (NormalizeI64s (__tl_make-array i64 0) 0))

(define (normalize-bools) : NormalizeBools
  (NormalizeBools (__tl_make-array bool 0) 0))

(define (normalize-i64s-push!
  [cells : (&mut cells NormalizeI64s)]
  [value : i64]) : unit
  (normalize-reserve! cells.items cells.len i64)
  (set! (array-ref cells.items cells.len) value)
  (set! cells.len (+ cells.len 1)))

(define (normalize-bools-push!
  [cells : (&mut cells NormalizeBools)]
  [value : bool]) : unit
  (normalize-reserve! cells.items cells.len bool)
  (set! (array-ref cells.items cells.len) value)
  (set! cells.len (+ cells.len 1)))

;; Room for cell `index` in an occurrence-indexed table (new cells are 0).
(defmacro (normalize-handle-reserve! [cells : Expr] [index : Expr]) : Expr
  `(when
    (>= ,index (array-length ,cells))
    (let
      [old : i64 (array-length ,cells)]
      [grown : (__tl_dyn-array i64) (__tl_make-array i64 (+ 8 (* 2 ,index)))]
      [at : i64 0]
      (while (< at old)
        (set! (array-ref grown at) (array-ref ,cells at))
        (set! at (+ at 1)))
      (set! ,cells grown))))

;; The live prefix of a growing array, at its exact length.
(defmacro (normalize-trimmed
  [cells : Expr]
  [count : Expr]
  ;; Spliced into the result's element type.
  ;; lint-allow: unused-variable
  [item-ty : Expr]) : Expr
  `(let
    [exact : (__tl_dyn-array ,item-ty) (__tl_make-array ,item-ty ,count)]
    [at : i64 0]
    (while (< at ,count)
      (set!
        (array-ref exact at)
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data ,cells) at))))
      (set! at (+ at 1)))
    exact))

(define (normalize-place-append!
  [state : (&mut state NormalizeState)]
  [place : own.OwnershipPlace]
  [name : i64]) : unit
  (normalize-reserve! state.body.places state.place-count own.OwnershipPlace)
  (normalize-reserve! state.field-names state.place-count i64)
  (normalize-reserve! state.place-typed state.place-count i64)
  (normalize-reserve! state.place-deref state.place-count i64)
  (normalize-reserve! state.region-roots state.place-count i64)
  (set! (array-ref state.body.places state.place-count) place)
  (set! (array-ref state.field-names state.place-count) name)
  (set! (array-ref state.place-typed state.place-count) -1)
  (set! (array-ref state.place-deref state.place-count) -1)
  (set! (array-ref state.region-roots state.place-count) -1)
  (set! state.place-count (+ state.place-count 1)))

;; Record a call for region instantiation: its callee signature's typed type
;; record, operand places (the callee first when indirect) and result place.
(define (normalize-note-call!
  [state : (&mut state NormalizeState)]
  [signature : i64]
  [operands : (& operands (__tl_dyn-array i64))]
  [result : i64]
  [indirect? : bool]) : unit
  (let
    [index : i64 0]
    (normalize-i64s-push! (&mut state.call-sigs) signature)
    (normalize-i64s-push! (&mut state.call-starts) state.call-operands.len)
    (normalize-i64s-push! (&mut state.call-counts) (array-length operands))
    (while (< index (array-length operands))
      (normalize-i64s-push!
        (&mut state.call-operands)
        (array-ref operands index))
      (set! index (+ index 1)))
    (normalize-i64s-push! (&mut state.call-results) result)
    (normalize-bools-push! (&mut state.call-indirect) indirect?)))

;; A synthetic place standing for the referent of reference place `through`:
;; its type is that reference's referent type, and it uses the region nodes of
;; the place the reference belongs to.
(define (normalize-note-deref!
  [state : (&mut state NormalizeState)]
  [place : i64]
  [through : i64]) : unit
  (when
    (and (>= place 0) (< place state.place-count) (>= through 0))
    (set! (array-ref state.place-deref place) through)
    (set!
      (array-ref state.region-roots place)
      (normalize-region-root (& state) through))))

;; The root place whose region nodes `place` uses: its own root, or for a
;; synthetic referent the region root of the reference it stands behind.
(define (normalize-region-root [state : (& state NormalizeState)] [place : i64]) : i64
  (let
    [root : i64 (normalize-place-root state place)]
    (if (and
      (< root (array-length state.region-roots))
      (>= (array-ref state.region-roots root) 0))
      (array-ref state.region-roots root)
      root)))

;; Record the typed type record of `place`'s value unless one is known.
(define (normalize-note-typed!
  [state : (&mut state NormalizeState)]
  [place : i64]
  [record : i64]) : unit
  (when
    (and
      (>= place 0)
      (< place state.place-count)
      (>= record 0)
      (< (array-ref state.place-typed place) 0))
    (set! (array-ref state.place-typed place) record)))

(define (normalize-local-append!
  [state : (&mut state NormalizeState)]
  [local : own.OwnershipLocal]) : unit
  (normalize-reserve! state.body.locals state.local-count own.OwnershipLocal)
  (set! (array-ref state.body.locals state.local-count) local)
  (set! state.local-count (+ state.local-count 1)))

(define (normalize-block-append!
  [state : (&mut state NormalizeState)]
  [block : own.OwnershipBlock]) : unit
  (normalize-reserve! state.body.blocks state.block-count own.OwnershipBlock)
  (normalize-reserve! state.instruction-counts state.block-count i64)
  (set! (array-ref state.body.blocks state.block-count) block)
  (set! (array-ref state.instruction-counts state.block-count) 0)
  (set! state.block-count (+ state.block-count 1)))

(define (normalize-instruction-append!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [instruction : own.OwnershipInstruction]) : unit
  (let
    [count : i64 (array-ref state.instruction-counts block)]
    (normalize-reserve!
      (array-ref state.body.blocks block).instructions
      count
      own.OwnershipInstruction)
    (set!
      (array-ref (array-ref state.body.blocks block).instructions count)
      instruction)
    (set! (array-ref state.instruction-counts block) (+ count 1))))

(define (normalize-loan-append!
  [state : (&mut state NormalizeState)]
  [loan : own.OwnershipLoan]) : unit
  (normalize-reserve! state.body.loans state.loan-count own.OwnershipLoan)
  (set! (array-ref state.body.loans state.loan-count) loan)
  (set! state.loan-count (+ state.loan-count 1)))

(define (normalize-node-append!
  [state : (&mut state NormalizeState)]
  [node : NormalizeNode]) : unit
  (let
    [slot : i64 node.handle.index]
    ;; The first node retained for an occurrence is the one its parent uses.
    (when
      (>= slot 0)
      (begin
        (normalize-handle-reserve! state.retained-at slot)
        (when
          (= (array-ref state.retained-at slot) 0)
          (set! (array-ref state.retained-at slot) (+ state.node-count 1)))))
    (normalize-reserve! state.nodes state.node-count NormalizeNode)
    (set! (array-ref state.nodes state.node-count) node)
    (set! state.node-count (+ state.node-count 1))))

;; Cuts one block's instructions to their live length.
(define (normalize-trim-block!
  [state : (&mut state NormalizeState)]
  [block : i64]) : unit
  (set!
    (array-ref state.body.blocks block).instructions
    (normalize-trimmed
      (array-ref state.body.blocks block).instructions
      (array-ref state.instruction-counts block)
      own.OwnershipInstruction)))

;; Cuts every growing array to its live length.
(define (normalize-trim! [state : (&mut state NormalizeState)]) : unit
  (let
    [block : i64 0]
    (set!
      state.body.places
      (normalize-trimmed state.body.places state.place-count own.OwnershipPlace))
    (set!
      state.field-names
      (normalize-trimmed state.field-names state.place-count i64))
    (set!
      state.body.locals
      (normalize-trimmed state.body.locals state.local-count own.OwnershipLocal))
    (set!
      state.body.blocks
      (normalize-trimmed state.body.blocks state.block-count own.OwnershipBlock))
    (while (< block state.block-count)
      (begin
        (normalize-trim-block! state block)
        (set! block (+ block 1))))
    (set!
      state.body.loans
      (normalize-trimmed state.body.loans state.loan-count own.OwnershipLoan))
    (set!
      state.nodes
      (normalize-trimmed state.nodes state.node-count NormalizeNode))
    (set!
      state.use-blocks
      (normalize-trimmed state.use-blocks state.use-count i64))
    (set!
      state.use-indices
      (normalize-trimmed state.use-indices state.use-count i64))
    (set!
      state.use-places
      (normalize-trimmed state.use-places state.use-count i64))
    (set!
      state.flow-from
      (normalize-trimmed state.flow-from state.flow-count i64))
    (set! state.flow-to (normalize-trimmed state.flow-to state.flow-count i64))
    (set!
      state.flow-outlives
      (normalize-trimmed state.flow-outlives state.flow-count bool))
    (set!
      state.flow-contents
      (normalize-trimmed state.flow-contents state.flow-count bool))
    (set!
      state.origin-places
      (normalize-trimmed state.origin-places state.origin-count i64))
    (set!
      state.origin-loans
      (normalize-trimmed state.origin-loans state.origin-count i64))))

(define (normalize-field-places!
  [state : (&mut state NormalizeState)]
  [parent : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [type : i64 (array-ref state.body.places parent).type.index]
    [local : i64 (array-ref state.body.places parent).local.index]
    [key : i64 (array-ref state.type-keys type)]
    [fields : (__tl_dyn-array i64) (normalize-product-fields (& state) type)]
    [ordinal : i64 0]
    (while (< ordinal (array-length fields))
      (let
        [place-source : own.OwnershipSource
          (try (normalize-source-copy! state source))]
        [name : i64
          (if (and
            (>= key 0)
            (< key (array-length state.products))
            (< ordinal (array-length (array-ref state.products key).names)))
            (array-ref (array-ref state.products key).names ordinal)
            (- -1 ordinal))]
        (try (normalize-charge! state 1 1 0))
        (normalize-place-append!
          state
          (own.OwnershipPlace
            (own.OwnershipLocalId
              (typed.typed-body-copy (& state.body.id))
              local)
            (own.OwnershipTypeId
              (typed.typed-body-copy (& state.body.id))
              (array-ref fields ordinal))
            (own.OwnershipProjection.Field
              (normalize-place-id (& state) parent)
              ordinal)
            place-source)
          name)
        (set! ordinal (+ ordinal 1))))
    (NormalizeUnit.Ok unit)))

;; The place of field `ordinal` of `parent`, expanding `parent` one level on its
;; first projection.
(define (normalize-field-place!
  [state : (&mut state NormalizeState)]
  [parent : i64]
  [ordinal : i64]) : NormalizeInt
  (let
    [found : i64 (normalize-field-place (& state) parent ordinal)]
    (if (or (>= found 0) (< parent 0) (normalize-expanded? (& state) parent))
      (NormalizeInt.Ok found)
      (let
        [parent-source : own.OwnershipSource
          (try (normalize-place-source-copy! state parent))]
        (try (normalize-field-places! state parent (& parent-source)))
        (NormalizeInt.Ok (normalize-field-place (& state) parent ordinal))))))

;; Whether some field place of `parent` exists (expansion is all-or-nothing).
(define (normalize-expanded? [state : (& state NormalizeState)] [parent : i64]) : bool
  (let
    [index : i64 (+ parent 1)]
    [found : bool false]
    (while (and (not found) (< index state.place-count))
      (begin
        (match (& (array-ref state.body.places index).projection)
          [(own.OwnershipProjection.Field owner _)
            (when (= owner.index parent) (set! found true))]
          [_ unit])
        (set! index (+ index 1))))
    found))

(define (normalize-cleanup-type?
  [state : (& state NormalizeState)]
  [type : i64]) : bool
  (and
    (>= type 0)
    (< type (array-length state.type-cleanups))
    (array-ref state.type-cleanups type)))

(define (normalize-copy-type? [state : (& state NormalizeState)] [type : i64]) : bool
  (array-ref state.body.types type).copy?)

(define (normalize-reference-kind
  [state : (& state NormalizeState)]
  [place : i64]) : i64
  (let
    [type : i64 (array-ref state.body.places place).type.index]
    (if (< type (array-length state.type-references))
      (array-ref state.type-references type)
      0)))

(define (normalize-note-use!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [index : i64]
  [place : i64]) : NormalizeUnit
  (if (= (normalize-reference-kind (& state) place) 0)
    (NormalizeUnit.Ok unit)
    (begin
      (try (normalize-charge! state 1 1 0))
      (normalize-reserve! state.use-blocks state.use-count i64)
      (normalize-reserve! state.use-indices state.use-count i64)
      (normalize-reserve! state.use-places state.use-count i64)
      (set! (array-ref state.use-blocks state.use-count) block)
      (set! (array-ref state.use-indices state.use-count) index)
      ;; An aggregate's parts share its loans (field-insensitive origins).
      (set!
        (array-ref state.use-places state.use-count)
        (normalize-place-root (& state) place))
      (set! state.use-count (+ state.use-count 1))
      (NormalizeUnit.Ok unit))))

(define (normalize-note-flow!
  [state : (&mut state NormalizeState)]
  [from : i64]
  [to : i64]) : NormalizeUnit
  (normalize-note-edge! state from to false false))

;; The loans borrowed place `from` holds also flow into the reference `to`
;; made to it: they stay live with it, but are its referent's contents.
(define (normalize-note-contents!
  [state : (&mut state NormalizeState)]
  [from : i64]
  [to : i64]) : NormalizeUnit
  (normalize-note-edge! state from to false true))

;; A read of `from` (a place of a split binding) redirected to the binding's
;; definition value `root`: the read keeps its own place, whose type spells the
;; binding's lifetime names, and takes its regions from `root`, whose type is
;; the binding's (`normalize-region-edges` relates regions by name).
(define (normalize-note-redirect!
  [state : (&mut state NormalizeState)]
  [from : i64]
  [root : i64]
  [to : i64]) : NormalizeUnit
  (let
    [count : i64 state.flow-count]
    (when
      (!= (normalize-reference-kind (& state) root) 0)
      (try (normalize-note-edge! state from to false false))
      (when
        (> state.flow-count count)
        (set!
          (array-ref state.flow-from count)
          (normalize-place-root (& state) root))))
    (NormalizeUnit.Ok unit)))

;; `to` (a reborrow made through the reference `from`) must not outlive the
;; loans `from` holds: they stay live while `to` is.
(define (normalize-note-outlives!
  [state : (&mut state NormalizeState)]
  [from : i64]
  [to : i64]) : NormalizeUnit
  (normalize-note-edge! state from to true false))

(define (normalize-note-edge!
  [state : (&mut state NormalizeState)]
  [from : i64]
  [to : i64]
  [outlives? : bool]
  [contents? : bool]) : NormalizeUnit
  (if (= (normalize-reference-kind (& state) from) 0)
    (NormalizeUnit.Ok unit)
    (begin
      (try (normalize-charge! state 1 1 0))
      (normalize-reserve! state.flow-from state.flow-count i64)
      (normalize-reserve! state.flow-to state.flow-count i64)
      (normalize-reserve! state.flow-outlives state.flow-count bool)
      (set! (array-ref state.flow-outlives state.flow-count) outlives?)
      (normalize-reserve! state.flow-contents state.flow-count bool)
      (set! (array-ref state.flow-contents state.flow-count) contents?)
      (normalize-reserve! state.flow-from-place state.flow-count i64)
      (normalize-reserve! state.flow-to-place state.flow-count i64)
      (set! (array-ref state.flow-from-place state.flow-count) from)
      (set! (array-ref state.flow-to-place state.flow-count) to)
      (set!
        (array-ref state.flow-from state.flow-count)
        (normalize-place-root (& state) from))
      (set!
        (array-ref state.flow-to state.flow-count)
        (normalize-place-root (& state) to))
      (set! state.flow-count (+ state.flow-count 1))
      (NormalizeUnit.Ok unit))))

(define (normalize-note-origin!
  [state : (&mut state NormalizeState)]
  [place : i64]
  [loan : i64]) : NormalizeUnit
  (try (normalize-charge! state 1 1 0))
  (normalize-reserve! state.origin-places state.origin-count i64)
  (normalize-reserve! state.origin-loans state.origin-count i64)
  (set!
    (array-ref state.origin-places state.origin-count)
    (normalize-place-root (& state) place))
  (set! (array-ref state.origin-loans state.origin-count) loan)
  (set! state.origin-count (+ state.origin-count 1))
  (NormalizeUnit.Ok unit))

;; A pattern node as the normalizer sees it: variant and literal tests are
;; opaque reads of their position.
(defenum NormalizePattern
  (Wildcard)
  (Bind typed.TypedBinderId)
  (Test)
  (Tuple)
  ;; An arm's binding or-pattern: its children are the candidate patterns.
  (Alternatives)
  ;; A slice pattern through a reference: a length test whose sub-patterns
  ;; have no positions; their binders derive from that reference.
  (Slice))

(defenum NormalizeOperation
  ;; Own the selected runtime payload before the inference lease is retired.
  ;; Neither lowering nor a certificate reader may recover it from source IDs.
  (Literal ast.AstLiteral)
  (Read typed.TypedBinderId)
  (Initialize typed.TypedBinderId)
  (Assign typed.TypedBinderId)
  (Unary ast.AstUnOp)
  (Binary ast.AstBinOp)
  (Sequence)
  (If)
  (While)
  (Break)
  (Continue)
  ;; Whether the return propagates a `try` failure (a generated return).
  (Return bool)
  ;; A call through its checked signature; the key is the declared callee's
  ;; canonical name key, or -1 for a callee value. Arguments are its children.
  ;; The first flag marks a call of the declared cleanup function of its
  ;; argument's type: it discharges a cleanup obligation. The second marks a
  ;; call through a function value, its child 0. Last, the typed type record
  ;; of the callee's signature (-1 when not yet read): the call relates its
  ;; operands and result through it (`normalize-region-edges`). Then the
  ;; typed call record's index (-1 when not yet read), which names the globals
  ;; the call may assign (`OwnershipNormalizeGlobalWrites`).
  (Call i64 i64 bool bool i64 i64)
  (Primitive typed.TypedPrimitive)
  ;; A formed place: it evaluates nothing itself. Only whole binders are
  ;; represented; projections stay outside the normalized subset.
  (FormPlace typed.TypedPlaceId)
  ;; `CopyPlace`/`MovePlace`: child 0 forms the place whose value is taken.
  (TakePlace)
  ;; Child 0 forms the place; child 1 is the value moved into it.
  (AssignPlace)
  ;; Child 0 forms the place; child 1 replaces its value; the result is the
  ;; old value.
  (ReplacePlace)
  (Borrow bool)
  (Match bool)
  (Arm)
  (Pattern NormalizePattern)
  ;; An arena destroy or rewind ends the binder's value.
  (Invalidate typed.TypedBinderId)
  ;; The `:invalidate` parameter's brand ends (its obligation is discharged).
  (EndBrand typed.TypedBinderId)
  ;; The atomic arena owner gains thread users (its marker is set).
  (ThreadUsers typed.TypedBinderId)
  ;; The first binder is released before the atomic arena owner (the second)
  ;; is: the owner's thread-users marker, or a thread handle, is empty.
  (RequireReleased typed.TypedBinderId typed.TypedBinderId)
  ;; The `with` owner (first) no longer holds values of the arena the second
  ;; binder names before its destroy (false) or rewind (true).
  (RequireUnheld typed.TypedBinderId typed.TypedBinderId bool))

(defenum NormalizeOperationResult
  (Ok NormalizeOperation)
  (Err OwnershipNormalizeFailure))

(define (normalize-unary-copy [op : (& op ast.AstUnOp)]) : ast.AstUnOp
  (match op
    [(ast.AstUnOp.Neg) ast.AstUnOp.Neg]
    [(ast.AstUnOp.Not) ast.AstUnOp.Not]
    [(ast.AstUnOp.BitNot) ast.AstUnOp.BitNot]))

(define (normalize-primitive-copy
  [primitive : (& primitive typed.TypedPrimitive)]) : typed.TypedPrimitive
  (match primitive
    [(typed.TypedPrimitive.Cast) typed.TypedPrimitive.Cast]
    [(typed.TypedPrimitive.PtrNull) typed.TypedPrimitive.PtrNull]
    [(typed.TypedPrimitive.PtrNullCheck) typed.TypedPrimitive.PtrNullCheck]
    [(typed.TypedPrimitive.PtrAddrOf) typed.TypedPrimitive.PtrAddrOf]
    [(typed.TypedPrimitive.PtrRead) typed.TypedPrimitive.PtrRead]
    [(typed.TypedPrimitive.PtrWrite) typed.TypedPrimitive.PtrWrite]
    [(typed.TypedPrimitive.PtrOffset) typed.TypedPrimitive.PtrOffset]
    [(typed.TypedPrimitive.PtrCast) typed.TypedPrimitive.PtrCast]
    [(typed.TypedPrimitive.PtrToInt) typed.TypedPrimitive.PtrToInt]
    [(typed.TypedPrimitive.IntToPtr) typed.TypedPrimitive.IntToPtr]
    [(typed.TypedPrimitive.RawRead arity) (typed.TypedPrimitive.RawRead arity)]
    [(typed.TypedPrimitive.RawWrite arity)
      (typed.TypedPrimitive.RawWrite arity)]
    [(typed.TypedPrimitive.Builtin code arity)
      (typed.TypedPrimitive.Builtin code arity)]))

(define (normalize-binary-copy [op : (& op ast.AstBinOp)]) : ast.AstBinOp
  (match op
    [(ast.AstBinOp.Add) ast.AstBinOp.Add]
    [(ast.AstBinOp.Sub) ast.AstBinOp.Sub]
    [(ast.AstBinOp.Mul) ast.AstBinOp.Mul]
    [(ast.AstBinOp.Div) ast.AstBinOp.Div]
    [(ast.AstBinOp.Mod) ast.AstBinOp.Mod]
    [(ast.AstBinOp.Eq) ast.AstBinOp.Eq]
    [(ast.AstBinOp.Ne) ast.AstBinOp.Ne]
    [(ast.AstBinOp.Lt) ast.AstBinOp.Lt]
    [(ast.AstBinOp.Le) ast.AstBinOp.Le]
    [(ast.AstBinOp.Gt) ast.AstBinOp.Gt]
    [(ast.AstBinOp.Ge) ast.AstBinOp.Ge]
    [(ast.AstBinOp.And) ast.AstBinOp.And]
    [(ast.AstBinOp.Or) ast.AstBinOp.Or]
    [(ast.AstBinOp.BitAnd) ast.AstBinOp.BitAnd]
    [(ast.AstBinOp.BitOr) ast.AstBinOp.BitOr]
    [(ast.AstBinOp.BitXor) ast.AstBinOp.BitXor]
    [(ast.AstBinOp.Shl) ast.AstBinOp.Shl]
    [(ast.AstBinOp.Shr) ast.AstBinOp.Shr]))

(define (normalize-operation
  [state : (&mut state NormalizeState)]
  [op : (& op typed.TypedOperation)]) : NormalizeOperationResult
  (match op
    [(typed.TypedOperation.Literal literal)
      (match literal
        [(ast.AstLiteral.Int value text)
          (try
            (normalize-charge!
              state
              0
              (string.string-length text)
              (string.string-length text)))
          (NormalizeOperationResult.Ok
            (NormalizeOperation.Literal
              (ast.AstLiteral.Int value (string.copy text))))]
        [(ast.AstLiteral.Float text)
          (try
            (normalize-charge!
              state
              0
              (string.string-length text)
              (string.string-length text)))
          (NormalizeOperationResult.Ok
            (NormalizeOperation.Literal
              (ast.AstLiteral.Float (string.copy text))))]
        [(ast.AstLiteral.Bool value)
          (NormalizeOperationResult.Ok
            (NormalizeOperation.Literal (ast.AstLiteral.Bool value)))]
        [(ast.AstLiteral.Char value)
          (NormalizeOperationResult.Ok
            (NormalizeOperation.Literal (ast.AstLiteral.Char value)))]
        [(ast.AstLiteral.Unit)
          (NormalizeOperationResult.Ok
            (NormalizeOperation.Literal ast.AstLiteral.Unit))]
        ;; A string literal produces a fresh owned String; the interned text is
        ;; static data, not a place any binding can alias.
        [(ast.AstLiteral.String id)
          (NormalizeOperationResult.Ok
            (NormalizeOperation.Literal (ast.AstLiteral.String id)))])]
    [(typed.TypedOperation.Read id)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Read
          (typed.TypedBinderId (typed.typed-handle-copy (& id.handle)))))]
    [(typed.TypedOperation.Initialize id)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Initialize
          (typed.TypedBinderId (typed.typed-handle-copy (& id.handle)))))]
    [(typed.TypedOperation.Invalidate id)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Invalidate
          (typed.TypedBinderId (typed.typed-handle-copy (& id.handle)))))]
    [(typed.TypedOperation.EndBrand id)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.EndBrand
          (typed.TypedBinderId (typed.typed-handle-copy (& id.handle)))))]
    [(typed.TypedOperation.ThreadUsers id)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.ThreadUsers
          (typed.TypedBinderId (typed.typed-handle-copy (& id.handle)))))]
    [(typed.TypedOperation.RequireReleased checked owner)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.RequireReleased
          (typed.TypedBinderId (typed.typed-handle-copy (& checked.handle)))
          (typed.TypedBinderId (typed.typed-handle-copy (& owner.handle)))))]
    [(typed.TypedOperation.RequireUnheld checked arena rewind?)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.RequireUnheld
          (typed.TypedBinderId (typed.typed-handle-copy (& checked.handle)))
          (typed.TypedBinderId (typed.typed-handle-copy (& arena.handle)))
          rewind?))]
    [(typed.TypedOperation.Assign id)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Assign
          (typed.TypedBinderId (typed.typed-handle-copy (& id.handle)))))]
    [(typed.TypedOperation.Unary unary)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Unary (normalize-unary-copy unary)))]
    [(typed.TypedOperation.Binary binary)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Binary (normalize-binary-copy binary)))]
    [(typed.TypedOperation.Sequence)
      (NormalizeOperationResult.Ok NormalizeOperation.Sequence)]
    [(typed.TypedOperation.If)
      (NormalizeOperationResult.Ok NormalizeOperation.If)]
    [(typed.TypedOperation.While)
      (NormalizeOperationResult.Ok NormalizeOperation.While)]
    [(typed.TypedOperation.Break)
      (NormalizeOperationResult.Ok NormalizeOperation.Break)]
    [(typed.TypedOperation.Continue)
      (NormalizeOperationResult.Ok NormalizeOperation.Continue)]
    [(typed.TypedOperation.Return)
      (NormalizeOperationResult.Ok (NormalizeOperation.Return false))]
    ;; The record is read after the occurrence view ends (`normalize-header!`).
    [(typed.TypedOperation.Call _)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Call -1 -1 false false -1 -1))]
    [(typed.TypedOperation.Primitive primitive)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Primitive (normalize-primitive-copy primitive)))]
    [(typed.TypedOperation.FormPlace place)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.FormPlace
          (typed.TypedPlaceId (typed.typed-handle-copy (& place.handle)))))]
    [(typed.TypedOperation.Borrow mutable?)
      (NormalizeOperationResult.Ok (NormalizeOperation.Borrow mutable?))]
    [(typed.TypedOperation.CopyPlace _)
      (NormalizeOperationResult.Ok NormalizeOperation.TakePlace)]
    [(typed.TypedOperation.Match borrowed?)
      (NormalizeOperationResult.Ok (NormalizeOperation.Match borrowed?))]
    [(typed.TypedOperation.Arm)
      (NormalizeOperationResult.Ok NormalizeOperation.Arm)]
    [(typed.TypedOperation.Pattern pattern)
      (NormalizeOperationResult.Ok
        (NormalizeOperation.Pattern
          (match pattern
            [(typed.TypedPattern.Bind id)
              (NormalizePattern.Bind
                (typed.TypedBinderId (typed.typed-handle-copy (& id.handle))))]
            [(typed.TypedPattern.Wildcard) NormalizePattern.Wildcard]
            [(typed.TypedPattern.Tuple) NormalizePattern.Tuple]
            [(typed.TypedPattern.Alternatives) NormalizePattern.Alternatives]
            [(typed.TypedPattern.Slice) NormalizePattern.Slice]
            [_ NormalizePattern.Test])))]
    [(typed.TypedOperation.MovePlace _)
      (NormalizeOperationResult.Ok NormalizeOperation.TakePlace)]
    [(typed.TypedOperation.AssignPlace _)
      (NormalizeOperationResult.Ok NormalizeOperation.AssignPlace)]
    [(typed.TypedOperation.ReplacePlace _)
      (NormalizeOperationResult.Ok NormalizeOperation.ReplacePlace)]
    [_
      (NormalizeOperationResult.Err
        (OwnershipNormalizeFailure.Unsupported
          "ownership normalization: projection requires representation semantics"))]))

(defstruct NormalizeHeader
  (type typed.TypedTypeId)
  (origin typed.TypedOriginId)
  (operation NormalizeOperation)
  (children i64))

(defenum NormalizeHeaderResult
  (Ok NormalizeHeader)
  (Err OwnershipNormalizeFailure))

(defstruct NormalizeNode
  (handle typed.TypedHandle)
  (type i64)
  (source own.OwnershipSource)
  (operation NormalizeOperation)
  (children (__tl_dyn-array typed.TypedOccurrenceId))
  (result-place i64)
  (operands (__tl_dyn-array i64))
  ;; The occurrence's typed type record (its lifetime names).
  (typed i64))

(defenum NormalizeNodeResult
  (Ok NormalizeNode)
  (Err OwnershipNormalizeFailure))

(defstruct NormalizeBinder
  (handle typed.TypedHandle)
  (type i64)
  (place i64)
  (parameter? bool)
  (initialized-definition? bool)
  (name i64)
  ;; 1 a `let` cleanup owner, 2 a `with` owner, 3 an affine handle (an arena
  ;; owner or phase token held as a Copy value), 0 none of these.
  (owner i64)
  ;; An `:invalidate` parameter's lifetime, or -1.
  (lifetime i64))

;; This is the owned result of the one selected-occurrence walk. The effect
;; body has passed the canonical checker; the accompanying selected values
;; preserve exactly the same tree for executable lowering. Handles remain
;; identities only and never authorize a later dereference into the old store.
(defstruct OwnershipNormalizedBody
  (body own.OwnershipBody)
  (nodes (__tl_dyn-array NormalizeNode))
  (binders (__tl_dyn-array NormalizeBinder))
  (root typed.TypedOccurrenceId)
  (return-type i64)
  (charged-records i64)
  (charged-work i64)
  (charged-bytes i64)
  (deferred OwnershipNormalizeDeferred)
  ;; The typed records of the global binders some loan borrows: only such a
  ;; global can conflict with a call's effect on it
  ;; (`OwnershipNormalizeGlobalWrites`).
  (borrowed-globals (__tl_dyn-array i64)))

(defstruct NormalizeState
  (body own.OwnershipBody)
  (classes (__tl_dyn-array OwnershipNormalizeTypeClass))
  (class-types (__tl_dyn-array i64))
  ;; Per body type: 0 value, 1 shared reference, 2 mutable reference.
  (type-references (__tl_dyn-array i64))
  ;; Per body type: its class owns a cleanup obligation.
  (type-cleanups (__tl_dyn-array bool))
  ;; Reference transport, solved after the walk: a direct loan a reference
  ;; place may hold, a flow of one reference place into another, and a use of a
  ;; reference place at an instruction position (the block's instruction
  ;; count is its terminator).
  (origin-places (__tl_dyn-array i64))
  (origin-loans (__tl_dyn-array i64))
  (flow-from (__tl_dyn-array i64))
  (flow-to (__tl_dyn-array i64))
  (use-blocks (__tl_dyn-array i64))
  (use-indices (__tl_dyn-array i64))
  (use-places (__tl_dyn-array i64))
  ;; Reborrow loans whose parent is the single solved origin of `place`.
  (reborrow-loans (__tl_dyn-array i64))
  (reborrow-places (__tl_dyn-array i64))
  ;; A reference parameter's referent is outside the body: it is a synthetic
  ;; initialized place borrowed once at entry, so reborrows through the
  ;; parameter are checked like any other loan.
  (parameter-loans (__tl_dyn-array i64))
  ;; The binder name of each parameter referent, for diagnostics, and the
  ;; reference binder's place (a `Deref` of it is the referent).
  (referent-places (__tl_dyn-array i64))
  (referent-names (__tl_dyn-array i64))
  (referent-binders (__tl_dyn-array i64))
  ;; A local reference binder initialized directly from one borrow, and that
  ;; loan: a `Deref` of the binder is the loan's place, reached through the
  ;; loan. Each dereference is rechecked once origins are solved: the binder's
  ;; origin must be exactly that loan (a reassigned, joined or copied-into
  ;; reference is outside the subset).
  (local-referents (__tl_dyn-array i64))
  (local-referent-loans (__tl_dyn-array i64))
  (deref-places (__tl_dyn-array i64))
  (deref-loans (__tl_dyn-array i64))
  ;; Shared reservation loans of two-phase mutable borrows: a conflict at the
  ;; reservation is reported as the mutable borrow it reserves.
  (reservation-loans (__tl_dyn-array i64))
  ;; Product shapes by class key; keys this body projects take their shape.
  (products (__tl_dyn-array OwnershipNormalizeProduct))
  (variances OwnershipNormalizeVariances)
  (global-writes OwnershipNormalizeGlobalWrites)
  ;; The places of the global binders the write table names, by typed binder
  ;; record, resolved before the walk (`normalize-global-places!`).
  (global-binders (__tl_dyn-array i64))
  (global-places (__tl_dyn-array i64))
  ;; Each global assignment a call made: the global's place, the call's
  ;; source position, and its effect-graph callee and global.
  (effect-places (__tl_dyn-array i64))
  (effect-sources (__tl_dyn-array own.OwnershipSource))
  (effect-callees (__tl_dyn-array i64))
  (effect-globals (__tl_dyn-array i64))
  ;; Each probe of a still unknown effect: its marker place (a fresh scalar
  ;; read at the call), the global's place, the nodes and the call's source.
  (probe-places (__tl_dyn-array i64))
  (probe-targets (__tl_dyn-array i64))
  (probe-callees (__tl_dyn-array i64))
  (probe-globals (__tl_dyn-array i64))
  (probe-sources (__tl_dyn-array own.OwnershipSource))
  (projected (__tl_dyn-array bool))
  ;; The class key of each body type (-1 for primitives) and the field name id
  ;; of each place (-1 for a root).
  (type-keys (__tl_dyn-array i64))
  (field-names (__tl_dyn-array i64))
  ;; The route of the last formed place: the parameter entry loan its accesses
  ;; go through and the reference binder they use, or -1 for an owned place.
  (formed-loan i64)
  (formed-binder i64)
  ;; Whether the last formed place is a part the checker cannot name, and
  ;; whether that part is box contents alone.
  (formed-indexed bool)
  (formed-boxed bool)
  ;; Whether the last formed place went through a fixed-array element, and the
  ;; flag the place walk sets while forming it.
  (formed-fixed bool)
  (walk-fixed bool)
  ;; Bindings recorded by match patterns awaiting their arm's block, and
  ;; whether each position is owned box contents (its place is the box).
  (pattern-binders (__tl_dyn-array typed.TypedBinderId))
  (pattern-positions (__tl_dyn-array i64))
  (pattern-boxed (__tl_dyn-array bool))
  ;; For a binder without a position, the reference place it derives from:
  ;; the scrutinee of a borrowed match, or a slice pattern's reference.
  (pattern-sources (__tl_dyn-array i64))
  ;; What consumes the value being walked, for a move-out diagnostic's wording
  ;; (`OwnershipMoveOutDiagnostic.context`).
  (move-context i64)
  ;; Two-phase mutable call borrows awaiting activation at their call: the
  ;; reservation loan, the borrowed place, the reference temporary and the
  ;; borrow's provenance. A call activates the entries it pushed.
  (reserved-loans (__tl_dyn-array i64))
  (reserved-places (__tl_dyn-array i64))
  (reserved-results (__tl_dyn-array i64))
  (reserved-sources (__tl_dyn-array own.OwnershipSource))
  ;; The child loan of an implicit reborrow of a mutable-reference binder (its
  ;; reservation is a shared loan of the binder itself, so the binder cannot
  ;; be reassigned before the call), or -1 for an explicit `(&mut place)`.
  (reserved-children (__tl_dyn-array i64))
  ;; The entry loan a reservation of a place behind a parameter reborrows, or -1.
  (reserved-parents (__tl_dyn-array i64))
  ;; Whether the reservation activates a shared reborrow (a read-only receiver)
  ;; rather than an exclusive one.
  (reserved-shared (__tl_dyn-array bool))
  (reserved-count i64)
  ;; Set while the walk reaches a read-only receiver operand (a slice element
  ;; read): an implicit reborrow of a mutable-reference binder there is shared,
  ;; as Rust's `Index::index(&*r)` is. `normalize-argument!` clears it.
  (shared-receiver bool)
  ;; Occurrence-indexed tables, one cell per typed occurrence handle index (0
  ;; when absent): whether the occurrence was loaded, and 1 + the index of its
  ;; retained node. A node is found by its handle; a scan over every earlier
  ;; node per node made normalization quadratic in the body's size.
  (seen (__tl_dyn-array i64))
  (retained-at (__tl_dyn-array i64))
  (nodes (__tl_dyn-array NormalizeNode))
  (binders (__tl_dyn-array NormalizeBinder))
  (limits OwnershipNormalizeLimits)
  (records i64)
  (work i64)
  (bytes i64)
  (return-type i64)
  (break-target i64)
  (continue-target i64)
  ;; Live lengths of the growing arrays (see `normalize-reserve!`): places
  ;; with their field names, locals, blocks with their instruction counts,
  ;; loans, nodes, seen occurrences, and the use, flow and origin notes.
  (place-count i64)
  (local-count i64)
  ;; The locals of module values referenced by the body.
  (global-locals (__tl_dyn-array i64))
  (block-count i64)
  (instruction-counts (__tl_dyn-array i64))
  (loan-count i64)
  (node-count i64)
  (seen-count i64)
  (use-count i64)
  (flow-count i64)
  (origin-count i64)
  ;; The block a place is being formed in (-1 outside a formation), and each
  ;; reference place dereferenced outside the parameter and local referent
  ;; subsets with the synthetic place standing for its referent.
  (form-block i64)
  (opaque-binders (__tl_dyn-array i64))
  (opaque-places (__tl_dyn-array i64))
  ;; Opaque-referent loans not yet issued: each is issued just before its
  ;; first access or reborrow, so it spans only that access.
  (deferred-loans (__tl_dyn-array i64))
  ;; Type-based regions (`normalize-solve-origins!`). Per place: the typed type
  ;; record its value has (-1 unknown), the reference place whose referent a
  ;; synthetic place stands for (-1 none), and the place whose region nodes it
  ;; uses (-1: its own root's).
  (place-typed (__tl_dyn-array i64))
  (place-deref (__tl_dyn-array i64))
  (region-roots (__tl_dyn-array i64))
  ;; Each call: its callee signature's typed type record, its operand places
  ;; (callee first when indirect), result place and whether it is indirect.
  (call-sigs NormalizeI64s)
  (call-starts NormalizeI64s)
  (call-counts NormalizeI64s)
  (call-operands NormalizeI64s)
  (call-results NormalizeI64s)
  (call-indirect NormalizeBools)
  ;; Places holding a returned value, and the place whose use at every return
  ;; demands the signature's (universal) regions.
  (return-places NormalizeI64s)
  (exit-holder i64)
  ;; Per flow edge, its two places before rooting (their types line the
  ;; regions up, `normalize-region-edges`).
  (flow-from-place (__tl_dyn-array i64))
  (flow-to-place (__tl_dyn-array i64))
  ;; Per flow edge: an outlives edge (a reborrow keeps the loans of the
  ;; reference it went through live) rather than a flow of the reference
  ;; itself. Outlives edges extend liveness only; the loans a reference points
  ;; into (reborrow parents, dereference checks) follow plain flows.
  (flow-outlives (__tl_dyn-array bool))
  ;; Per flow edge: the flow of a borrowed place's own loans into the
  ;; reference to it (a reference to a place holding references keeps those
  ;; loans too). Such loans are the referent's contents, not where the
  ;; reference points, so the dereference identity check ignores them.
  (flow-contents (__tl_dyn-array bool))
  ;; Loans lending an array to an element store `(set! (array-ref a i) v)`: a
  ;; conflict there is reported as the assignment it is.
  (store-loans (__tl_dyn-array i64))
  ;; Cleanup owners in scope, innermost last (`owner-count` live entries): the
  ;; binder place, 1 a `let` owner or 2 a `with` owner, the loop depth it was
  ;; bound at and, for a `let` owner, its whole-discharge marker: a scalar set
  ;; when the owner moves out whole (moving its fields one by one does not
  ;; discharge it). `loop-depth` counts the loop bodies around the walk.
  (owner-places (__tl_dyn-array i64))
  (owner-kinds (__tl_dyn-array i64))
  (owner-depths (__tl_dyn-array i64))
  (owner-markers (__tl_dyn-array i64))
  (owner-count i64)
  (loop-depth i64)
  ;; Exit checks: the block and the checked place (origin solving later
  ;; inserts uses, so instruction indices move; one exit per block checks a
  ;; place once), the owner place, the check (0 the owner is empty, 1 its
  ;; marker is clear, 2 a `with` owner is present) and the exit kind (see
  ;; `OwnershipObligationDiagnostic`).
  (exit-blocks (__tl_dyn-array i64))
  (exit-places (__tl_dyn-array i64))
  (exit-owners (__tl_dyn-array i64))
  (exit-checks (__tl_dyn-array i64))
  (exit-kinds (__tl_dyn-array i64))
  ;; Places holding a value moved whole out of a `let` owner (-1 once
  ;; consumed): the obligation travels with the value to its consumer. The
  ;; owner's name and the move's source accompany it.
  (obligation-values (__tl_dyn-array i64))
  (obligation-names (__tl_dyn-array i64))
  (obligation-sources (__tl_dyn-array own.OwnershipSource))
  ;; Parallel to `store-loans`: the literal element index a store writes
  ;; (`(set! (array-ref a 0) v)`), or -1; diagnostics name the element.
  (store-elements (__tl_dyn-array i64))
  ;; The literal index of the fixed-array element place just formed, or -1.
  (formed-element i64)
  ;; Accesses of a literal fixed-array element (the access is to the whole
  ;; array place): block, place and source position, and the element index a
  ;; diagnostic names there (`items[0]`).
  (element-blocks (__tl_dyn-array i64))
  (element-places (__tl_dyn-array i64))
  (element-lines (__tl_dyn-array i64))
  (element-columns (__tl_dyn-array i64))
  (element-values (__tl_dyn-array i64))
  ;; Parallel to `exit-blocks`: the atomic arena owner place a release check
  ;; guards (exits 6 and 7), or -1.
  (exit-arenas (__tl_dyn-array i64))
  ;; Atomic arena owner places with a thread-users marker: a scalar local,
  ;; empty at entry, set when a value of the owner's region crosses threads.
  (thread-owners (__tl_dyn-array i64))
  (thread-markers (__tl_dyn-array i64))
  ;; The places the tails of the control-flow store receiver being walked
  ;; selected (form 150), formed but not yet borrowed (see
  ;; `normalize-receiver-store!`), and how many such receivers are open.
  (receiver-targets (__tl_dyn-array NormalizeDeferredReceiver))
  (receiver-depth i64))

(define (normalize-charge!
  [state : (&mut state NormalizeState)]
  [records : i64]
  [work : i64]
  [bytes : i64]) : NormalizeUnit
  (if (and
    (>= records 0)
    (>= work 0)
    (>= bytes 0)
    (<= records (- state.limits.records state.records))
    (<= work (- state.limits.work state.work))
    (<= bytes (- state.limits.source-bytes state.bytes)))
    (begin
      (set! state.records (+ state.records records))
      (set! state.work (+ state.work work))
      (set! state.bytes (+ state.bytes bytes))
      (NormalizeUnit.Ok unit))
    (NormalizeUnit.Err OwnershipNormalizeFailure.Resource)))

(define (normalize-source-copy!
  [state : (&mut state NormalizeState)]
  [source : (& source own.OwnershipSource)]) : NormalizeSource
  (try (normalize-source-charge! state source))
  (normalize-source-clone source))

(define (normalize-source-charge!
  [state : (&mut state NormalizeState)]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [path : i64 (string.string-length (& source.path))]
    [expansion : i64 (string.string-length (& source.expansion))]
    (try (normalize-charge! state 1 path path))
    (normalize-charge! state 0 expansion expansion)))

(define (normalize-source-clone [source : (& source own.OwnershipSource)]) : NormalizeSource
  (if (own.ownership-source-valid? source)
    (NormalizeSource.Ok
      (own.OwnershipSource
        (string.copy (& source.path))
        source.line
        source.column
        (string.copy (& source.expansion))))
    (NormalizeSource.Err
      (OwnershipNormalizeFailure.Structural
        "ownership normalization: invalid provenance"))))

;; Copies of provenance the state itself holds: the charge mutates the state,
;; so the source is measured and copied through separate borrows.
(define (normalize-place-source-copy!
  [state : (&mut state NormalizeState)]
  [place : i64]) : NormalizeSource
  (let
    [measured : own.OwnershipSource
      (try
        (normalize-source-clone (& (array-ref state.body.places place).source)))]
    (try (normalize-source-charge! state (& measured)))
    (NormalizeSource.Ok measured)))

(define (normalize-loan-source-copy!
  [state : (&mut state NormalizeState)]
  [loan : i64]) : NormalizeSource
  (let
    [measured : own.OwnershipSource
      (try
        (normalize-source-clone (& (array-ref state.body.loans loan).source)))]
    (try (normalize-source-charge! state (& measured)))
    (NormalizeSource.Ok measured)))

(define (normalize-node-source-copy!
  [state : (&mut state NormalizeState)]
  [node : i64]) : NormalizeSource
  (let
    [measured : own.OwnershipSource
      (try (normalize-source-clone (& (array-ref state.nodes node).source)))]
    (try (normalize-source-charge! state (& measured)))
    (NormalizeSource.Ok measured)))

(define (normalize-header!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]) : NormalizeHeaderResult
  (let
    [call : i64 -1]
    [header : NormalizeHeader
      (match (typed.typed-occurrence-get! store lease id)
        [(typed.TypedNodeResult.Ok node)
          (let
            [_category : unit
              (match (& node.category)
                [(typed.TypedOccurrenceCategory.Value) unit]
                [_
                  (match (& node.operation)
                    [(typed.TypedOperation.FormPlace _) unit]
                    [_
                      (return
                        (NormalizeHeaderResult.Err
                          (OwnershipNormalizeFailure.Unsupported
                            "ownership normalization: place formation requires representation semantics")))])])]
            [operation : NormalizeOperation
              (let
                [operation : NormalizeOperation
                  (try (normalize-operation state (& node.operation)))]
                (match (& operation)
                  ;; A generated return is a `try` propagating its failure.
                  [(NormalizeOperation.Return _)
                    (NormalizeOperation.Return
                      (match (& node.syntax)
                        [(typed.TypedSyntax.Generated) true]
                        [_ false]))]
                  [_ operation]))]
            (match (& node.operation)
              [(typed.TypedOperation.Call record)
                (set! call record.handle.index)]
              [_ unit])
            (NormalizeHeader
              (typed.TypedTypeId (typed.typed-handle-copy (& node.type.handle)))
              (typed.TypedOriginId
                (typed.typed-handle-copy (& node.origin.handle)))
              operation
              node.child-count))]
        [(typed.TypedNodeResult.Err error)
          (return
            (NormalizeHeaderResult.Err (OwnershipNormalizeFailure.Typed error)))])]
    (if (< call 0)
      (NormalizeHeaderResult.Ok header)
      (NormalizeHeaderResult.Ok
        (NormalizeHeader
          header.type
          header.origin
          (try (normalize-call-operation! store lease id))
          header.children)))))

(define (normalize-call-operation!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]) : NormalizeOperationResult
  (let
    [record : typed.TypedCallId
      (match (typed.typed-occurrence-get! store lease id)
        [(typed.TypedNodeResult.Ok node)
          (match (& node.operation)
            [(typed.TypedOperation.Call record)
              (typed.TypedCallId (typed.typed-handle-copy (& record.handle)))]
            [_
              (return
                (NormalizeOperationResult.Err
                  (OwnershipNormalizeFailure.Structural
                    "ownership normalization: call record changed")))])]
        [(typed.TypedNodeResult.Err error)
          (return
            (NormalizeOperationResult.Err
              (OwnershipNormalizeFailure.Typed error)))])]
    (match (typed.typed-call-get! store lease record)
      [(typed.TypedCallView.Ok call)
        (let
          [key : i64
            (match (& call.kind)
              [(typed.TypedCallKind.Declared key) key]
              [(typed.TypedCallKind.Foreign key) key]
              [(typed.TypedCallKind.Discharge key) key]
              [_ -1])]
          ;; A call through a function value has the callee as child 0.
          [indirect? : bool
            (match (& call.kind)
              [(typed.TypedCallKind.Indirect _) true]
              [_ false])]
          ;; A constructor takes owners over into its value, as the declared
          ;; cleanup function discharges them.
          [discharge? : bool
            (match (& call.kind)
              [(typed.TypedCallKind.Discharge _) true]
              [(typed.TypedCallKind.Construct) true]
              [_ false])]
          ;; The call's children: its arguments, after the callee if any.
          [count : i64
            (if indirect?
              (+ call.argument-count 1)
              call.argument-count)]
          [signature-index : i64 call.signature.handle.index]
          (NormalizeOperationResult.Ok
            (NormalizeOperation.Call
              key
              count
              discharge?
              indirect?
              signature-index
              record.handle.index)))]
      [(typed.TypedCallView.Err error)
        (NormalizeOperationResult.Err (OwnershipNormalizeFailure.Typed error))])))

(define (normalize-node!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]) : NormalizeNodeResult
  (let
    [header : NormalizeHeader (try (normalize-header! state store lease id))]
    (unless
      (and
        (>= header.children 0)
        (<= header.children (- state.limits.records 2)))
      (return (NormalizeNodeResult.Err OwnershipNormalizeFailure.Resource)))
    (when
      (< id.handle.index 0)
      (return
        (NormalizeNodeResult.Err
          (OwnershipNormalizeFailure.Structural
            "ownership normalization: invalid occurrence handle"))))
    (normalize-handle-reserve! state.seen id.handle.index)
    (when
      (!= (array-ref state.seen id.handle.index) 0)
      (return
        (NormalizeNodeResult.Err
          (OwnershipNormalizeFailure.Structural
            "ownership normalization: executable occurrence has multiple parents"))))
    (try
      (normalize-charge! state (+ 2 header.children) (+ 1 header.children) 0))
    (set! (array-ref state.seen id.handle.index) 1)
    (set! state.seen-count (+ state.seen-count 1))
    (let
      [type : i64 (try (normalize-type! state store lease header.type))]
      [source : own.OwnershipSource
        (match (typed.typed-origin-get! store lease header.origin)
          [(typed.TypedOriginView.Ok source)
            (try (normalize-source-copy! state source))]
          [(typed.TypedOriginView.Err error)
            (return
              (NormalizeNodeResult.Err (OwnershipNormalizeFailure.Typed error)))])]
      [children : (__tl_dyn-array typed.TypedOccurrenceId)
        (__tl_make-array typed.TypedOccurrenceId 0)]
      [ordinal : i64 0]
      (while (< ordinal header.children)
        (begin
          (match (typed.typed-child-get! store lease id ordinal)
            [(typed.TypedChildResult.Ok child)
              (__tl_array-push! children child)]
            [(typed.TypedChildResult.Err error)
              (return
                (NormalizeNodeResult.Err
                  (OwnershipNormalizeFailure.Typed error)))])
          (set! ordinal (+ ordinal 1))))
      (NormalizeNodeResult.Ok
        (NormalizeNode
          (typed.typed-handle-copy (& id.handle))
          type
          source
          header.operation
          children
          -1
          (__tl_make-array i64 0)
          header.type.handle.index)))))

(define (normalize-place-id [state : (& state NormalizeState)] [index : i64]) : own.OwnershipPlaceId
  (own.OwnershipPlaceId (typed.typed-body-copy (& state.body.id)) index))

(define (normalize-block-id [state : (& state NormalizeState)] [index : i64]) : own.OwnershipBlockId
  (own.OwnershipBlockId (typed.typed-body-copy (& state.body.id)) index))

(define (normalize-local!
  [state : (&mut state NormalizeState)]
  [type : i64]
  [parameter? : bool]
  [source : (& source own.OwnershipSource)]) : NormalizeInt
  (let
    [index : i64 state.place-count]
    [local : i64 state.local-count]
    [local-source : own.OwnershipSource
      (try (normalize-source-copy! state source))]
    [place-source : own.OwnershipSource
      (try (normalize-source-copy! state source))]
    (try (normalize-charge! state 2 2 0))
    (unless
      (normalize-storage-type? (& state) type)
      (return
        (NormalizeInt.Err
          (OwnershipNormalizeFailure.Structural
            "ownership normalization: exit cannot have storage"))))
    (normalize-local-append!
      state
      (own.OwnershipLocal
        (own.OwnershipTypeId (typed.typed-body-copy (& state.body.id)) type)
        parameter?
        local-source))
    (normalize-place-append!
      state
      (own.OwnershipPlace
        (own.OwnershipLocalId (typed.typed-body-copy (& state.body.id)) local)
        (own.OwnershipTypeId (typed.typed-body-copy (& state.body.id)) type)
        own.OwnershipProjection.Root
        place-source)
      -1)
    (NormalizeInt.Ok index)))

(define (normalize-block!
  [state : (&mut state NormalizeState)]
  [source : (& source own.OwnershipSource)]) : NormalizeInt
  (let
    [index : i64 state.block-count]
    [copy : own.OwnershipSource (try (normalize-source-copy! state source))]
    (try (normalize-charge! state 2 2 0))
    (normalize-block-append!
      state
      (own.OwnershipBlock
        (__tl_make-array own.OwnershipInstruction 0)
        own.OwnershipTerminator.Abort
        copy))
    (NormalizeInt.Ok index)))

(define (normalize-emit!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [operation : own.OwnershipOperation]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [_deferred : unit
      (match (& operation)
        [(own.OwnershipOperation.AccessThrough loan _ access)
          (try
            (normalize-issue-deferred!
              state
              block
              loan.index
              (match access
                [(own.OwnershipAccess.Write) true]
                [(own.OwnershipAccess.Read) false])))]
        [_ unit])]
    [copy : own.OwnershipSource (try (normalize-source-copy! state source))]
    [index : i64 (array-ref state.instruction-counts block)]
    ;; A reference read here is a use of every loan its origin may hold; a
    ;; reference copied or moved also flows that origin into its destination.
    [used : i64
      (match (& operation)
        [(own.OwnershipOperation.Read place) place.index]
        [(own.OwnershipOperation.Copy source _) source.index]
        [(own.OwnershipOperation.Move source _) source.index]
        [(own.OwnershipOperation.Consume place) place.index]
        [_ -1])]
    [flowed : i64
      (match (& operation)
        [(own.OwnershipOperation.Copy _ dest) dest.index]
        [(own.OwnershipOperation.Move _ dest) dest.index]
        [_ -1])]
    (try (normalize-charge! state 1 1 0))
    (when
      (>= used 0)
      (begin
        (try (normalize-note-use! state block index used))
        (when (>= flowed 0) (try (normalize-note-flow! state used flowed)))))
    (normalize-instruction-append!
      state
      block
      (own.OwnershipInstruction operation copy))
    (NormalizeUnit.Ok unit)))

;; The initialization check of a Copy destination about to be overwritten. The
;; overwrite reads nothing, so it demands none of the loans the old value
;; holds (as in Rust, where assigning to a reference variable does not use it);
;; the write itself still conflicts with every loan of the destination.
(define (normalize-emit-init-check!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [place : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [copy : own.OwnershipSource (try (normalize-source-copy! state source))]
    (try (normalize-charge! state 1 1 0))
    (normalize-instruction-append!
      state
      block
      (own.OwnershipInstruction
        (own.OwnershipOperation.Read (normalize-place-id (& state) place))
        copy))
    (NormalizeUnit.Ok unit)))

(define (normalize-terminate!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [term : own.OwnershipTerminator]) : NormalizeUnit
  (let
    [at : i64 (array-ref state.instruction-counts block)]
    [index : i64 0]
    (try (normalize-charge! state 1 1 0))
    ;; A returned reference is used at the exit edge.
    (match (& term)
      [(own.OwnershipTerminator.Return operands)
        (while (< index (array-length operands.items))
          (begin
            (try
              (normalize-note-use!
                state
                block
                at
                (array-ref operands.items index).index))
            (set! index (+ index 1))))]
      [(own.OwnershipTerminator.ReturnOwned operands)
        (while (< index (array-length operands.items))
          (begin
            (try
              (normalize-note-use!
                state
                block
                at
                (array-ref operands.items index).index))
            (set! index (+ index 1))))]
      [_ unit])
    (set! (array-ref state.body.blocks block).terminator term)
    (NormalizeUnit.Ok unit)))

;; A negative block is an exit. Later syntactic children still normalize into
;; disconnected blocks so malformed or unsupported dead forms cannot certify.
(defstruct NormalizeValue
  (type i64)
  (place i64)
  (block i64))

(defenum NormalizeValueResult
  (Ok NormalizeValue)
  (Err OwnershipNormalizeFailure))

(defstruct NormalizeBinderHeader
  (type typed.TypedTypeId)
  (origin typed.TypedOriginId)
  (parameter? bool)
  ;; A module value: a permanent static place, initialized at entry and never
  ;; moved out of.
  (global? bool)
  (name i64)
  ;; 1 a `let` cleanup owner, 2 a `with` owner, 3 an affine handle (an arena
  ;; owner or phase token held as a Copy value), 0 none of these.
  (owner i64)
  ;; An `:invalidate` parameter's lifetime, or -1.
  (lifetime i64))

(defenum NormalizeBinderHeaderResult
  (Ok NormalizeBinderHeader)
  (Err OwnershipNormalizeFailure))

(define (normalize-binder-header!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedBinderId]) : NormalizeBinderHeaderResult
  (match (typed.typed-binder-get! store lease id)
    [(typed.TypedBinderView.Ok binder)
      (let
        [parameter? : bool
          (match (& binder.kind)
            [(typed.TypedBinderKind.Parameter) true]
            [(typed.TypedBinderKind.Local) false]
            [(typed.TypedBinderKind.Owner) false]
            [(typed.TypedBinderKind.WithOwner _) false]
            [(typed.TypedBinderKind.MoveAwareOwner _) false]
            [(typed.TypedBinderKind.Affine) false]
            [(typed.TypedBinderKind.InvalidateParameter _) true]
            ;; Initialized by the first child of the place formed on it.
            [(typed.TypedBinderKind.Temporary) false]
            [(typed.TypedBinderKind.Global _) false]
            ;; A lambda body's captured value is in its environment at entry.
            [(typed.TypedBinderKind.Capture) true])]
        [global? : bool
          (match (& binder.kind)
            [(typed.TypedBinderKind.Global _) true]
            [_ false])]
        (NormalizeBinderHeaderResult.Ok
          (NormalizeBinderHeader
            (typed.TypedTypeId (typed.typed-handle-copy (& binder.type.handle)))
            (typed.TypedOriginId
              (typed.typed-handle-copy (& binder.origin.handle)))
            parameter?
            global?
            binder.name
            (match (& binder.kind)
              [(typed.TypedBinderKind.Owner) 1]
              [(typed.TypedBinderKind.WithOwner _) 2]
              [(typed.TypedBinderKind.Affine) 3]
              ;; Cleanup effects only (`normalize-owner-cleanup-writes!`).
              [(typed.TypedBinderKind.MoveAwareOwner _) 6]
              [_ 0])
            (match (& binder.kind)
              [(typed.TypedBinderKind.InvalidateParameter lifetime) lifetime]
              [_ -1]))))]
    [(typed.TypedBinderView.Err error)
      (NormalizeBinderHeaderResult.Err (OwnershipNormalizeFailure.Typed error))]))

(define (normalize-binder!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedBinderId]) : NormalizeInt
  (let
    [header : NormalizeBinderHeader
      (try (normalize-binder-header! store lease id))]
    [type : i64 (try (normalize-type! state store lease header.type))]
    [index : i64 0]
    (while (< index (array-length state.binders))
      (begin
        (try (normalize-charge! state 0 1 0))
        (when
          (= (array-ref state.binders index).handle.index id.handle.index)
          (return (NormalizeInt.Ok (array-ref state.binders index).place)))
        (set! index (+ index 1))))
    (let
      [source : own.OwnershipSource
        (match (typed.typed-origin-get! store lease header.origin)
          [(typed.TypedOriginView.Ok source)
            (try (normalize-source-copy! state source))]
          [(typed.TypedOriginView.Err error)
            (return (NormalizeInt.Err (OwnershipNormalizeFailure.Typed error)))])]
      ;; Parameters and module values are initialized at entry.
      [place : i64
        (try
          (normalize-local!
            state
            type
            (if header.parameter?
              true
              header.global?)
            (& source)))]
      (try (normalize-charge! state 1 1 0))
      (normalize-note-typed! state place header.type.handle.index)
      (when
        header.global?
        (__tl_array-push!
          state.global-locals
          (array-ref state.body.places place).local.index))
      (__tl_array-push!
        state.binders
        (NormalizeBinder
          (typed.typed-handle-copy (& id.handle))
          type
          place
          header.parameter?
          false
          header.name
          header.owner
          header.lifetime))
      (NormalizeInt.Ok place))))

;; Initialize is the single static declaration event, not a generic write.
;; A future loop may execute that occurrence repeatedly. Distinct source
;; declarations, including shadows, must have distinct resolved binder IDs.
(define (normalize-initializer!
  [state : (&mut state NormalizeState)]
  [place : i64]) : NormalizeUnit
  (let
    [index : i64 0]
    (while (< index (array-length state.binders))
      (begin
        (try (normalize-charge! state 0 1 0))
        (when
          (= (array-ref state.binders index).place place)
          (when
            (or
              (array-ref state.binders index).parameter?
              (array-ref state.binders index).initialized-definition?)
            (return
              (NormalizeUnit.Err
                (OwnershipNormalizeFailure.Structural
                  "ownership normalization: binder has multiple declaration initializers"))))
          (set! (array-ref state.binders index).initialized-definition? true)
          (return (NormalizeUnit.Ok unit)))
        (set! index (+ index 1))))
    (NormalizeUnit.Err
      (OwnershipNormalizeFailure.Structural
        "ownership normalization: missing initializer binder"))))

;; Parameters are bound in canonical declaration order before body inference.
;; Visit all published binders through leased accessors so unused aggregate,
;; region, or cleanup-bearing parameters cannot silently certify as scalars.
(define (normalize-parameters!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]) : NormalizeUnit
  (let
    [count : i64
      (match (typed.typed-binder-count! store lease)
        [(typed.TypedCountResult.Ok value) value]
        [(typed.TypedCountResult.Err error)
          (return (NormalizeUnit.Err (OwnershipNormalizeFailure.Typed error)))])]
    [index : i64 0]
    (try (normalize-charge! state 0 count 0))
    (while (< index count)
      (let
        [id : typed.TypedBinderId
          (match (typed.typed-binder-at! store lease index)
            [(typed.TypedBinderResult.Ok value) value]
            [(typed.TypedBinderResult.Err error)
              (return
                (NormalizeUnit.Err (OwnershipNormalizeFailure.Typed error)))])]
        [parameter? : bool
          (match (typed.typed-binder-get! store lease id)
            [(typed.TypedBinderView.Ok binder)
              (match (& binder.kind)
                [(typed.TypedBinderKind.Parameter) true]
                [(typed.TypedBinderKind.InvalidateParameter _) true]
                [_ false])]
            [(typed.TypedBinderView.Err error)
              (return
                (NormalizeUnit.Err (OwnershipNormalizeFailure.Typed error)))])]
        (when
          parameter?
          (let
            [place : i64 (try (normalize-binder! state store lease id))]
            [kind : i64 (normalize-reference-kind (& state) place)]
            [_brand : unit
              (when
                (>= (normalize-binder-lifetime (& state) place) 0)
                (try (normalize-brand-owner! state place)))]
            (when
              (> kind 0)
              (let
                [source : own.OwnershipSource
                  (try (normalize-place-source-copy! state place))]
                [referent : i64
                  (try
                    (normalize-local!
                      state
                      (try
                        (normalize-referent-type!
                          state
                          store
                          lease
                          (typed.TypedBinderId
                            (typed.typed-handle-copy (& id.handle)))))
                      true
                      (& source)))]
                [loan : i64 state.loan-count]
                (try (normalize-charge! state 1 1 0))
                (normalize-loan-append!
                  state
                  (own.OwnershipLoan
                    (normalize-place-id (& state) referent)
                    (if (= kind 2)
                      own.OwnershipLoanKind.Exclusive
                      own.OwnershipLoanKind.Shared)
                    own.OwnershipLoanOrigin.Direct
                    source))
                (__tl_array-push! state.parameter-loans loan)
                (__tl_array-push! state.referent-places referent)
                (__tl_array-push! state.referent-binders place)
                (normalize-note-deref! state referent place)
                (__tl_array-push!
                  state.referent-names
                  (normalize-binder-name (& state) place))
                (try (normalize-note-origin! state place loan))))))
        (set! index (+ index 1))))
    (NormalizeUnit.Ok unit)))

;; The body type of a reference parameter's referent when its class names a
;; representable one; otherwise an opaque unit placeholder that no projection
;; can reach (the referent then only anchors the entry loan).
(define (normalize-referent-type!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedBinderId]) : NormalizeInt
  (let
    [header : NormalizeBinderHeader
      (try (normalize-binder-header! store lease id))]
    [index : i64 header.type.handle.index]
    [referent : i64
      (if (< index (array-length state.classes))
        (array-ref state.classes index).referent
        -1)]
    (if (< referent 0)
      (NormalizeInt.Ok 0)
      (match (typed.typed-type-at! store lease referent)
        [(typed.TypedTypeIdResult.Ok target)
          (match (normalize-type! state store lease target)
            [(NormalizeInt.Ok type) (NormalizeInt.Ok type)]
            [(NormalizeInt.Err _) (NormalizeInt.Ok 0)])]
        [(typed.TypedTypeIdResult.Err error)
          (NormalizeInt.Err (OwnershipNormalizeFailure.Typed error))]))))

;; A route at a view binder's own place: a shared reference kind whose type
;; (the typed `container`) names a referent.
(define (normalize-view-route?
  [state : (& state NormalizeState)]
  [route : (& route NormalizePlaceRoute)]
  [container : i64]) : bool
  (and
    (< route.loan 0)
    (not route.indexed)
    (>= route.place 0)
    (> (normalize-reference-kind state route.place) 0)
    (>= container 0)
    (< container (array-length state.classes))
    (>= (array-ref state.classes container).referent 0)))

;; The normalized referent type of the typed type `container` (a reference or
;; a view), or -1.
(define (normalize-class-referent-type!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [container : i64]) : NormalizeInt
  (let
    [referent : i64
      (if (and (>= container 0) (< container (array-length state.classes)))
        (array-ref state.classes container).referent
        -1)]
    (if (< referent 0)
      (NormalizeInt.Ok -1)
      (match (typed.typed-type-at! store lease referent)
        [(typed.TypedTypeIdResult.Ok target)
          (match (normalize-type! state store lease target)
            [(NormalizeInt.Ok type) (NormalizeInt.Ok type)]
            [(NormalizeInt.Err _) (NormalizeInt.Ok -1)])]
        [(typed.TypedTypeIdResult.Err error)
          (NormalizeInt.Err (OwnershipNormalizeFailure.Typed error))]))))

(define (normalize-integer? [type : i64]) : bool
  (and (>= type 2) (<= type 9)))

(define (normalize-number? [type : i64]) : bool
  (and (>= type 2) (<= type 11)))

(define (normalize-literal-type?
  [literal : (& literal ast.AstLiteral)]
  [type : i64]) : bool
  (match literal
    [(ast.AstLiteral.Int _ _) (normalize-integer? type)]
    [(ast.AstLiteral.Float _) (or (= type 10) (= type 11))]
    [(ast.AstLiteral.Bool _) (= type 1)]
    [(ast.AstLiteral.Char _) (= type 12)]
    [(ast.AstLiteral.Unit) (= type 0)]
    [(ast.AstLiteral.String _) (not (normalize-primitive-type? type))]))

(define (normalize-unary-type?
  [op : (& op ast.AstUnOp)]
  [input : i64]
  [output : i64]) : bool
  (and
    (= input output)
    (match op
      [(ast.AstUnOp.Not) (= input 1)]
      [(ast.AstUnOp.Neg) (normalize-number? input)]
      [(ast.AstUnOp.BitNot) (normalize-integer? input)])))

(define (normalize-binary-type?
  [op : (& op ast.AstBinOp)]
  [left : i64]
  [right : i64]
  [output : i64]) : bool
  (match op
    [(ast.AstBinOp.And) (and (= left 1) (= right 1) (= output 1))]
    [(ast.AstBinOp.Or) (and (= left 1) (= right 1) (= output 1))]
    [(ast.AstBinOp.Eq) (and (= left right) (= output 1) (< left 13))]
    [(ast.AstBinOp.Ne) (and (= left right) (= output 1) (< left 13))]
    [(ast.AstBinOp.Lt)
      (and
        (= left right)
        (= output 1)
        (or (normalize-number? left) (= left 12)))]
    [(ast.AstBinOp.Le)
      (and
        (= left right)
        (= output 1)
        (or (normalize-number? left) (= left 12)))]
    [(ast.AstBinOp.Gt)
      (and
        (= left right)
        (= output 1)
        (or (normalize-number? left) (= left 12)))]
    [(ast.AstBinOp.Ge)
      (and
        (= left right)
        (= output 1)
        (or (normalize-number? left) (= left 12)))]
    [(ast.AstBinOp.Shl)
      (and (normalize-integer? left) (normalize-integer? right) (= left output))]
    [(ast.AstBinOp.Shr)
      (and (normalize-integer? left) (normalize-integer? right) (= left output))]
    [(ast.AstBinOp.Mod)
      (and (= left right) (= left output) (normalize-integer? left))]
    [(ast.AstBinOp.BitAnd)
      (and (= left right) (= left output) (normalize-integer? left))]
    [(ast.AstBinOp.BitOr)
      (and (= left right) (= left output) (normalize-integer? left))]
    [(ast.AstBinOp.BitXor)
      (and (= left right) (= left output) (normalize-integer? left))]
    [_ (and (= left right) (= left output) (normalize-number? left))]))

;; Builtin forms whose operands move in instead of taking two-phase mutable
;; borrows: a tuple literal (form 129), a closure's captures (form 135) and a
;; spawned thread's task (form 136).
(define (normalize-builtin-moves-operands? [code : i64]) : bool
  (or (= code 129) (= code 135) (= code 136)))

;; A builtin form that only reads through its receiver operand (operand 0): a
;; slice element read (form 124). A mutable-reference receiver is reborrowed
;; shared for it.
(define (normalize-builtin-reads-receiver? [code : i64]) : bool
  (= code 124))

(define (normalize-value!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [type : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeValueResult
  (let
    [place : i64 (try (normalize-local! state type false source))]
    (try
      (normalize-emit!
        state
        block
        ;; A computed Copy value may execute again through a backedge. Its
        ;; static temporary is overwritten; it is not a resource acquisition.
        (own.OwnershipOperation.Assign (normalize-place-id (& state) place))
        source))
    (NormalizeValueResult.Ok (NormalizeValue type place block))))

(define (normalize-type-error) : OwnershipNormalizeFailure
  (OwnershipNormalizeFailure.Structural
    "ownership normalization: selected operation/type mismatch"))

(define (normalize-copy!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [source-place : i64]
  [dest : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (normalize-emit!
    state
    block
    (own.OwnershipOperation.Copy
      (normalize-place-id (& state) source-place)
      (normalize-place-id (& state) dest))
    source))

(define (normalize-primitive-type? [type : i64]) : bool
  (and (>= type 0) (< type normalize-first-value-type)))

;; A Copy value is copied. A move-only value is transferred and leaves its
;; source empty, so a later read of the source is rejected.
(define (normalize-transfer!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [source-place : i64]
  [dest : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  ;; A value carrying an owner's obligation carries it on.
  (let
    [tagged : i64 (normalize-obligation-index (& state) source-place)]
    (when (>= tagged 0) (set! (array-ref state.obligation-values tagged) dest)))
  (if (normalize-copy-type?
    (& state)
    (array-ref state.body.places source-place).type.index)
    (normalize-copy! state block source-place dest source)
    (begin
      ;; A module value is never moved out of (SPEC global places).
      (when
        (normalize-global-local?
          (& state)
          (array-ref state.body.places source-place).local.index)
        (return
          (NormalizeUnit.Err
            (try (normalize-global-move-out state source-place source)))))
      (normalize-emit!
        state
        block
        (own.OwnershipOperation.Move
          (normalize-place-id (& state) source-place)
          (normalize-place-id (& state) dest))
        source))))

;; Moving `place`'s value out of a module value (SPEC global places): the
;; diagnostic names the global (kind 3).
(defenum NormalizeFailureResult
  (Ok OwnershipNormalizeFailure)
  (Err OwnershipNormalizeFailure))

(define (normalize-global-move-out
  [state : (&mut state NormalizeState)]
  [place : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeFailureResult
  (NormalizeFailureResult.Ok
    (OwnershipNormalizeFailure.MoveOut
      (OwnershipMoveOutDiagnostic
        (normalize-binder-name (& state) (normalize-place-root (& state) place))
        (__tl_make-array i64 0)
        3
        (try (normalize-source-copy! state source))
        NormalizeMaybeType.No
        state.move-context))))

(define (normalize-global-local?
  [state : (& state NormalizeState)]
  [local : i64]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index (array-length state.global-locals)))
      (when (= (array-ref state.global-locals index) local) (set! found true))
      (set! index (+ index 1)))
    found))

(define (normalize-child-id [node : (& node NormalizeNode)] [index : i64]) : typed.TypedOccurrenceId
  (typed.TypedOccurrenceId
    (typed.typed-handle-copy (& (array-ref node.children index).handle))))

(define (normalize-retain-node!
  [state : (&mut state NormalizeState)]
  [node : NormalizeNode]
  [result-place : i64]) : NormalizeUnit
  (normalize-note-typed! state result-place node.typed)
  (let
    [child : i64 0]
    (try
      (normalize-charge!
        state
        (+ 1 (array-length node.children))
        (+ 1 (array-length node.children))
        0))
    (while (< child (array-length node.children))
      (let
        [slot : i64 (array-ref node.children child).handle.index]
        [index : i64
          (if (and (>= slot 0) (< slot (array-length state.retained-at)))
            (- (array-ref state.retained-at slot) 1)
            -1)]
        (unless
          (if (< index 0)
            false
            (typed.typed-handle-equal?
              (& (array-ref state.nodes index).handle)
              (& (array-ref node.children child).handle)))
          (return
            (NormalizeUnit.Err
              (OwnershipNormalizeFailure.Structural
                "ownership normalization: missing selected operand"))))
        (__tl_array-push!
          node.operands
          (array-ref state.nodes index).result-place)
        (set! child (+ child 1))))
    (set! node.result-place result-place)
    (normalize-node-append! state node)
    (NormalizeUnit.Ok unit)))

(define (normalize-walk!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (unless
    (and (>= depth 0) (< depth state.limits.depth))
    (return (NormalizeValueResult.Err OwnershipNormalizeFailure.Resource)))
  (try (normalize-charge! state 1 1 0))
  (let
    [node : NormalizeNode (try (normalize-node! state store lease id))]
    [active : i64
      (if (< block 0)
        (try (normalize-block! state (& node.source)))
        block)]
    [value : NormalizeValue
      (try (normalize-execute! state store lease (& node) active (+ depth 1)))]
    (normalize-note-typed! state value.place node.typed)
    (try (normalize-retain-node! state node value.place))
    (NormalizeValueResult.Ok value)))

(define (normalize-unary!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [op : (& op ast.AstUnOp)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [input : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    ;; A diverging operand is an exit.
    (when (= input.type 13) (return (NormalizeValueResult.Ok input)))
    (if (or
      (not (normalize-primitive-type? input.type))
      (not (normalize-primitive-type? node.type)))
      (NormalizeValueResult.Err
        (OwnershipNormalizeFailure.Unsupported
          "ownership normalization: unary operand outside primitive values"))
      (if (normalize-unary-type? op input.type node.type)
        (begin
          (try
            (normalize-emit!
              state
              input.block
              (own.OwnershipOperation.Read
                (normalize-place-id (& state) input.place))
              (& node.source)))
          (normalize-value! state input.block node.type (& node.source)))
        (NormalizeValueResult.Err (normalize-type-error))))))

(define (normalize-short-circuit!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [left : NormalizeValue]
  [and? : bool]
  [depth : i64]) : NormalizeValueResult
  (let
    [right-block : i64 (try (normalize-block! state (& node.source)))]
    [merge : i64 (try (normalize-block! state (& node.source)))]
    [result : i64 (try (normalize-local! state 1 false (& node.source)))]
    (unless
      (and (= left.type 1) (= node.type 1))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (try (normalize-copy! state left.block left.place result (& node.source)))
    (try
      (normalize-terminate!
        state
        left.block
        (own.OwnershipTerminator.Branch
          (normalize-place-id (& state) left.place)
          (normalize-block-id
            (& state)
            (if and?
              right-block
              merge))
          (normalize-block-id
            (& state)
            (if and?
              merge
              right-block)))))
    (let
      [right : NormalizeValue
        (try
          (normalize-walk!
            state
            store
            lease
            (normalize-child-id node 1)
            right-block
            depth))]
      (unless
        (or (= right.type 1) (= right.type 13))
        (return (NormalizeValueResult.Err (normalize-type-error))))
      (when
        (>= right.block 0)
        (begin
          (try
            (normalize-copy!
              state
              right.block
              right.place
              result
              (& node.source)))
          (try
            (normalize-terminate!
              state
              right.block
              (own.OwnershipTerminator.Goto
                (normalize-block-id (& state) merge))))))
      (NormalizeValueResult.Ok (NormalizeValue 1 result merge)))))

(define (normalize-binary!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [op : (& op ast.AstBinOp)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [left : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    (cond
      [(and
          (= left.type 1)
          (match op
            [(ast.AstBinOp.And) true]
            [(ast.AstBinOp.Or) true]
            [_ false]))
        (normalize-short-circuit!
          state
          store
          lease
          node
          left
          (match op
            [(ast.AstBinOp.And) true]
            [_ false])
          depth)]
      ;; A diverging operand makes the operation unreachable: a right operand
      ;; after a diverging left one is walked in a block nothing reaches.
      [(= left.type 13)
        (let
          [dead : i64 (try (normalize-block! state (& node.source)))]
          (try
            (normalize-walk!
              state
              store
              lease
              (normalize-child-id node 1)
              dead
              depth))
          (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1)))]
      [else
        (let
          [right : NormalizeValue
            (try
              (normalize-walk!
                state
                store
                lease
                (normalize-child-id node 1)
                left.block
                depth))]
          (cond
            [(= right.type 13)
              (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))]
            [(or
                (not (normalize-binary-operand? (& state) left.type))
                (not (normalize-binary-operand? (& state) right.type))
                (not (normalize-binary-operand? (& state) node.type)))
              (NormalizeValueResult.Err
                (OwnershipNormalizeFailure.Unsupported
                  "ownership normalization: binary operand outside primitive values"))]
            [(or
              ;; Copy operands that are not primitive (raw pointers, Copy
              ;; aggregates) are read like scalars.
              (not
                (and
                  (normalize-primitive-type? left.type)
                  (normalize-primitive-type? right.type)
                  (normalize-primitive-type? node.type)))
              (normalize-binary-type? op left.type right.type node.type))
              (try
                (normalize-emit!
                  state
                  right.block
                  (own.OwnershipOperation.Read
                    (normalize-place-id (& state) left.place))
                  (& node.source)))
              (try
                (normalize-emit!
                  state
                  right.block
                  (own.OwnershipOperation.Read
                    (normalize-place-id (& state) right.place))
                  (& node.source)))
              (normalize-value! state right.block node.type (& node.source))]
            [else (NormalizeValueResult.Err (normalize-type-error))]))])))

;; A binary operand or result: a primitive, or a Copy value holding no loans.
(define (normalize-binary-operand?
  [state : (& state NormalizeState)]
  [type : i64]) : bool
  (or
    (normalize-primitive-type? type)
    (and
      (normalize-storage-type? state type)
      (normalize-copy-type? state type)
      (or
        (>= type (array-length state.type-references))
        (= (array-ref state.type-references type) 0)))))

(define (normalize-if!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [condition : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    [left-block : i64 (try (normalize-block! state (& node.source)))]
    [right-block : i64 (try (normalize-block! state (& node.source)))]
    [merge : i64 (try (normalize-block! state (& node.source)))]
    (unless
      (or (= condition.type 1) (= condition.type 13))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (when
      (>= condition.block 0)
      (try
        (normalize-terminate!
          state
          condition.block
          (own.OwnershipTerminator.Branch
            (normalize-place-id (& state) condition.place)
            (normalize-block-id (& state) left-block)
            (normalize-block-id (& state) right-block)))))
    (let
      [left : NormalizeValue
        (try
          (normalize-walk-in-context!
            state
            store
            lease
            (normalize-child-id node 1)
            left-block
            depth
            0))]
      [right : NormalizeValue
        (try
          (normalize-walk-in-context!
            state
            store
            lease
            (normalize-child-id node 2)
            right-block
            depth
            0))]
      [joined : i64
        (if (= left.type 13)
          right.type
          left.type)]
      (unless
        (and
          (or (= left.type right.type) (= left.type 13) (= right.type 13))
          (=
            node.type
            (if (= condition.type 13)
              13
              joined)))
        (return (NormalizeValueResult.Err (normalize-type-error))))
      (if (= node.type 13)
        (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))
        (let
          [result : i64
            (try (normalize-local! state node.type false (& node.source)))]
          (when
            (>= left.block 0)
            (begin
              (try
                (normalize-transfer!
                  state
                  left.block
                  left.place
                  result
                  (& node.source)))
              (try
                (normalize-terminate!
                  state
                  left.block
                  (own.OwnershipTerminator.Goto
                    (normalize-block-id (& state) merge))))))
          (when
            (>= right.block 0)
            (begin
              (try
                (normalize-transfer!
                  state
                  right.block
                  right.place
                  result
                  (& node.source)))
              (try
                (normalize-terminate!
                  state
                  right.block
                  (own.OwnershipTerminator.Goto
                    (normalize-block-id (& state) merge))))))
          (NormalizeValueResult.Ok (NormalizeValue node.type result merge)))))))

;; --- Cleanup obligations (SPEC 4.7.1, 5.19) --------------------------------
;;
;; A `let` owner of a cleanup-owning aggregate must be discharged on every exit
;; of its scope: by its declared cleanup function, by moving it whole into
;; another owner, a cleanup-owning aggregate or the function result. A `with`
;; owner's cleanup runs on every exit, so no exit may find it moved. Each exit
;; is checked where it leaves the owner's scope; the checks are recorded so a
;; core failure there is reported as the obligation it breaks.
;; The owner kind of a binder place: 1 a `let` owner, 2 a `with` owner, 0 none.
;; The `:invalidate` lifetime of the parameter at `place`, or -1.
(define (normalize-binder-lifetime
  [state : (& state NormalizeState)]
  [place : i64]) : i64
  (let
    [index : i64 0]
    [lifetime : i64 -1]
    (while (and (< lifetime 0) (< index (array-length state.binders)))
      (when
        (= (array-ref state.binders index).place place)
        (set! lifetime (array-ref state.binders index).lifetime))
      (set! index (+ index 1)))
    lifetime))

(define (normalize-cleanup-owner? [kind : i64]) : bool
  (or (= kind 1) (= kind 2)))

(define (normalize-binder-owner
  [state : (& state NormalizeState)]
  [place : i64]) : i64
  (let
    [index : i64 0]
    [kind : i64 0]
    (while (and (= kind 0) (< index (array-length state.binders)))
      (when
        (= (array-ref state.binders index).place place)
        (set! kind (array-ref state.binders index).owner))
      (set! index (+ index 1)))
    kind))

;; An owner bound at `block`. A `let` owner's marker is set there, since a
;; loop rebinds the owner on every iteration: only moving the owner out whole
;; clears it, so fields moved one by one leave it set.
(define (normalize-owner-bind!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [place : i64]
  [kind : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [marker : i64
      (if (= kind 1)
        (try (normalize-local! state 1 false source))
        -1)]
    (when
      (>= marker 0)
      (try
        (normalize-emit!
          state
          block
          (own.OwnershipOperation.Assign (normalize-place-id (& state) marker))
          source)))
    (try (normalize-charge! state 0 4 0))
    (if (< state.owner-count (array-length state.owner-places))
      (begin
        (set! (array-ref state.owner-places state.owner-count) place)
        (set! (array-ref state.owner-kinds state.owner-count) kind)
        (set! (array-ref state.owner-depths state.owner-count) state.loop-depth)
        (set! (array-ref state.owner-markers state.owner-count) marker))
      (begin
        (__tl_array-push! state.owner-places place)
        (__tl_array-push! state.owner-kinds kind)
        (__tl_array-push! state.owner-depths state.loop-depth)
        (__tl_array-push! state.owner-markers marker)))
    (set! state.owner-count (+ state.owner-count 1))
    (NormalizeUnit.Ok unit)))

;; An `:invalidate` parameter's brand obligation (owner kind 5): a marker
;; local set at entry (as a parameter is), ended by `EndBrand`, and required
;; empty at every exit of the function.
(define (normalize-brand-owner!
  [state : (&mut state NormalizeState)]
  [place : i64]) : NormalizeUnit
  (let
    [source : own.OwnershipSource
      (try (normalize-place-source-copy! state place))]
    [marker : i64 (try (normalize-local! state 1 true (& source)))]
    (try (normalize-charge! state 0 4 0))
    (__tl_array-push! state.owner-places place)
    (__tl_array-push! state.owner-kinds 5)
    (__tl_array-push! state.owner-depths 0)
    (__tl_array-push! state.owner-markers marker)
    (set! state.owner-count (+ state.owner-count 1))
    (NormalizeUnit.Ok unit)))

;; `EndBrand` of the `:invalidate` parameter at `place`: its marker empties.
(define (normalize-end-brand!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [place : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [index : i64 0]
    [marker : i64 -1]
    (while (and (< marker 0) (< index state.owner-count))
      (when
        (and
          (= (array-ref state.owner-kinds index) 5)
          (= (array-ref state.owner-places index) place))
        (set! marker (array-ref state.owner-markers index)))
      (set! index (+ index 1)))
    (if (< marker 0)
      (NormalizeUnit.Err
        (OwnershipNormalizeFailure.Structural
          "ownership normalization: brand end without an :invalidate parameter"))
      (normalize-emit!
        state
        block
        (own.OwnershipOperation.Invalidate
          (normalize-place-id (& state) marker))
        source))))

;; A `let` owner moved out whole into `dest` at `block`: its marker is
;; cleared, and its obligation travels with the value.
(define (normalize-owner-moved!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [place : i64]
  [dest : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [index : i64 (- state.owner-count 1)]
    [marker : i64 -1]
    (while (and (< marker 0) (>= index 0))
      (when
        (= (array-ref state.owner-places index) place)
        (set! marker (array-ref state.owner-markers index)))
      (set! index (- index 1)))
    (if (< marker 0)
      (NormalizeUnit.Ok unit)
      (begin
        (try
          (normalize-emit!
            state
            block
            (own.OwnershipOperation.Invalidate
              (normalize-place-id (& state) marker))
            source))
        (try (normalize-charge! state 0 3 0))
        (let
          [name : i64 (normalize-binder-name (& state) place)]
          [moved : own.OwnershipSource
            (try (normalize-source-copy! state source))]
          (__tl_array-push! state.obligation-values dest)
          (__tl_array-push! state.obligation-names name)
          (__tl_array-push! state.obligation-sources moved))
        (NormalizeUnit.Ok unit)))))

(define (normalize-obligation-index
  [state : (& state NormalizeState)]
  [place : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (while (and (< found 0) (< index (array-length state.obligation-values)))
      (when
        (= (array-ref state.obligation-values index) place)
        (set! found index))
      (set! index (+ index 1)))
    found))

;; `place` is consumed here: a value carrying a `let` owner's obligation is
;; discharged by a discharging consumer and lost by any other.
(define (normalize-obligation-consume!
  [state : (&mut state NormalizeState)]
  [place : i64]
  [discharge? : bool]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [index : i64 (normalize-obligation-index (& state) place)]
    (cond
      [(< index 0) (NormalizeUnit.Ok unit)]
      [discharge?
        (set! (array-ref state.obligation-values index) -1)
        (NormalizeUnit.Ok unit)]
      [else
        (NormalizeUnit.Err
          (OwnershipNormalizeFailure.Obligation
            (OwnershipObligationDiagnostic
              (array-ref state.obligation-names index)
              2
              -1
              (try (normalize-source-copy! state source))
              -1
              -1
              NormalizeMoveDiagnosticResult.No
              (own.ownership-source-copy source))))])))

;; Before storing into owned place `place` of a cleanup-owning type: it must
;; be empty, or the store loses the old value's cleanup (exit kind 8, reported
;; as an overwrite).
(define (normalize-overwrite-check!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [place : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (normalize-exit-check!
    state
    block
    place
    place
    0
    8
    (own.OwnershipOperation.RequireEmpty (normalize-place-id (& state) place))
    source))

(define (normalize-exit-check!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [owner : i64]
  [checked : i64]
  [check : i64]
  [exit : i64]
  [operation : own.OwnershipOperation]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (try (normalize-charge! state 0 5 0))
  (try (normalize-emit! state block operation source))
  (__tl_array-push! state.exit-blocks block)
  (__tl_array-push! state.exit-places checked)
  (__tl_array-push! state.exit-owners owner)
  (__tl_array-push! state.exit-checks check)
  (__tl_array-push! state.exit-kinds exit)
  (__tl_array-push! state.exit-arenas -1)
  (NormalizeUnit.Ok unit))

;; The thread-users marker of atomic arena owner `owner`, made on first use (a
;; local is empty at entry, so a later-made marker is no weaker).
(define (normalize-thread-marker!
  [state : (&mut state NormalizeState)]
  [owner : i64]) : NormalizeInt
  (let
    [index : i64 0]
    [found : i64 -1]
    (while (and (< found 0) (< index (array-length state.thread-owners)))
      (when
        (= (array-ref state.thread-owners index) owner)
        (set! found (array-ref state.thread-markers index)))
      (set! index (+ index 1)))
    (if (>= found 0)
      (NormalizeInt.Ok found)
      (let
        [source : own.OwnershipSource
          (try (normalize-place-source-copy! state owner))]
        [marker : i64 (try (normalize-local! state 1 false (& source)))]
        (try (normalize-charge! state 0 2 0))
        (__tl_array-push! state.thread-owners owner)
        (__tl_array-push! state.thread-markers marker)
        (NormalizeInt.Ok marker)))))

;; Before atomic arena owner `owner` is destroyed or rewound: `user` is the
;; owner itself (its thread-users marker must be clear, exit 6) or a thread
;; handle holding its region (it must have been joined, exit 7).
(define (normalize-release-check!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [user : i64]
  [owner : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [hidden? : bool (= user owner)]
    [checked : i64
      (if hidden?
        (try (normalize-thread-marker! state owner))
        user)]
    (try
      (normalize-exit-check!
        state
        block
        user
        checked
        0
        (if hidden?
          6
          7)
        (own.OwnershipOperation.RequireEmpty
          (normalize-place-id (& state) checked))
        source))
    (set!
      (array-ref state.exit-arenas (- (array-length state.exit-arenas) 1))
      owner)
    (NormalizeUnit.Ok unit)))

;; Check the owners from `first` up, innermost first, at an exit of kind `exit`
;; that leaves their scopes. A `with` owner's cleanup consumes it here.
(define (normalize-exit-owners!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [first : i64]
  [exit : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [index : i64 (- state.owner-count 1)]
    (while (>= index first)
      (let
        [place : i64 (array-ref state.owner-places index)]
        [marker : i64 (array-ref state.owner-markers index)]
        (cond
          ;; The cleanup runs with the owner still held, so its effects come
          ;; before the owner is consumed.
          [(= (array-ref state.owner-kinds index) 2)
            (try (normalize-owner-cleanup-writes! state block place source))
            (try
              (normalize-exit-check!
                state
                block
                place
                place
                2
                exit
                (own.OwnershipOperation.Consume
                  (normalize-place-id (& state) place))
                source))]
          ;; A move-aware `with` owner's cleanup runs at an exit while it
          ;; still owns its value: its effects apply there, and the loans it
          ;; holds stay live to there whether or not it was moved out (Rust's
          ;; drop-liveness, without the init test).
          [(= (array-ref state.owner-kinds index) 6)
            (try (normalize-owner-cleanup-writes! state block place source))
            (try
              (normalize-note-use!
                state
                block
                (array-ref state.instruction-counts block)
                place))]
          ;; An `:invalidate` brand must have ended.
          [(= (array-ref state.owner-kinds index) 5)
            (try
              (normalize-exit-check!
                state
                block
                place
                marker
                0
                exit
                (own.OwnershipOperation.RequireEmpty
                  (normalize-place-id (& state) marker))
                source))]
          [else
            (try
              (normalize-exit-check!
                state
                block
                place
                place
                0
                exit
                (own.OwnershipOperation.RequireEmpty
                  (normalize-place-id (& state) place))
                source))
            (try
              (normalize-exit-check!
                state
                block
                place
                marker
                1
                exit
                (own.OwnershipOperation.RequireEmpty
                  (normalize-place-id (& state) marker))
                source))])
        (set! index (- index 1))))
    (NormalizeUnit.Ok unit)))

;; The first owner a loop exit leaves: those bound in the innermost loop body.
(define (normalize-loop-owners [state : (& state NormalizeState)]) : i64
  (let
    [index : i64 0]
    (while (and
      (< index state.owner-count)
      (< (array-ref state.owner-depths index) state.loop-depth))
      (set! index (+ index 1)))
    index))

;; A failure at a recorded exit check, as the obligation it breaks.
(define (normalize-obligation-diagnostic
  [state : (& state NormalizeState)]
  [failure : (& failure own.OwnershipFailure)]) : NormalizeObligationDiagnosticResult
  (let
    [checked : i64
      (if (and
        (>= failure.block 0)
        (< failure.block (array-length state.body.blocks))
        (>= failure.instruction 0)
        (<
          failure.instruction
          (array-length
            (array-ref state.body.blocks failure.block).instructions)))
        (match (&
          (array-ref
            (array-ref state.body.blocks failure.block).instructions
            failure.instruction).operation)
          [(own.OwnershipOperation.RequireEmpty place) place.index]
          [(own.OwnershipOperation.Consume place) place.index]
          [_ -1])
        -1)]
    ;; A `with` owner's scope-exit cleanup (check 2) is a Consume; every other
    ;; check is a RequireEmpty. A block may hold both for one place (a
    ;; `RequireUnheld` before the scope ends), so the kind tells them apart.
    [consume? : bool
      (and
        (>= checked 0)
        (match (&
          (array-ref
            (array-ref state.body.blocks failure.block).instructions
            failure.instruction).operation)
          [(own.OwnershipOperation.Consume _) true]
          [_ false]))]
    [index : i64 0]
    [found : i64 -1]
    (while (and
      (>= checked 0)
      (< found 0)
      (< index (array-length state.exit-blocks)))
      (when
        (and
          (= (array-ref state.exit-blocks index) failure.block)
          (= (array-ref state.exit-places index) checked)
          (= (= (array-ref state.exit-checks index) 2) consume?))
        (set! found index))
      (set! index (+ index 1)))
    (if (< found 0)
      NormalizeObligationDiagnosticResult.No
      (let
        [check : i64 (array-ref state.exit-checks found)]
        [maybe? : bool
          (string.eq
            failure.message
            "place that must be empty may hold a value")]
        [status : i64
          (cond
            [(= check 2) 4]
            [maybe? 1]
            [(= check 1) 3]
            [(string.eq
                failure.message
                "place that must be empty partly holds a value")
              3]
            [else 0])]
        (NormalizeObligationDiagnosticResult.Some
          (OwnershipObligationDiagnostic
            (normalize-binder-name state (array-ref state.exit-owners found))
            status
            (array-ref state.exit-kinds found)
            (own.ownership-source-copy (& failure.source))
            (normalize-binder-lifetime
              state
              (array-ref state.exit-owners found))
            (if (< (array-ref state.exit-arenas found) 0)
              -1
              (normalize-binder-name state (array-ref state.exit-arenas found)))
            (if (= status 4)
              (normalize-move-search
                state
                checked
                failure.block
                failure.instruction
                false)
              NormalizeMoveDiagnosticResult.No)
            (own.ownership-source-copy
              (&
                (array-ref
                  state.body.places
                  (array-ref state.exit-owners found)).source))))))))

(defenum NormalizeObligationDiagnosticResult
  (Some OwnershipObligationDiagnostic)
  (No))

(define (normalize-sequence!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [index : i64 0]
    [active : i64 block]
    [last-type : i64 0]
    [last-place : i64 -1]
    [exited? : bool false]
    ;; Owners bound by this sequence's `let` initializers end with it.
    [owners : i64 state.owner-count]
    (while (< index (array-length node.children))
      (let
        ;; Only the last form's value flows on; the others are discarded.
        [value : NormalizeValue
          (try
            (if (< (+ index 1) (array-length node.children))
              (normalize-walk-in-context!
                state
                store
                lease
                (normalize-child-id node index)
                active
                depth
                0)
              (normalize-walk!
                state
                store
                lease
                (normalize-child-id node index)
                active
                depth)))]
        (set! exited? (or exited? (= value.type 13)))
        (set!
          active
          (if exited?
            -1
            value.block))
        (set! last-type value.type)
        (set! last-place value.place)
        (set! index (+ index 1))))
    (unless
      (=
        node.type
        (if exited?
          13
          last-type))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (when
      (and (not exited?) (> state.owner-count owners))
      (try
        (normalize-exit-owners!
          state
          (if (< last-place 0)
            block
            active)
          owners
          0
          (& node.source))))
    (set! state.owner-count owners)
    (cond
      [exited? (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))]
      [(< last-place 0) (normalize-value! state block 0 (& node.source))]
      [else
        (NormalizeValueResult.Ok (NormalizeValue last-type last-place active))])))

;; A selected condition and body each expand once. Repetition exists only in
;; the canonical CFG, so condition effects run again after continue/backedges.
;; The scalar source language has no labelled exits: the bounded recursive
;; traversal saves/restores the nearest lexical body's two exact targets.
(define (normalize-while!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [condition-block : i64 (try (normalize-block! state (& node.source)))]
    [body-block : i64 (try (normalize-block! state (& node.source)))]
    [exit-block : i64 (try (normalize-block! state (& node.source)))]
    ;; A diverging condition is an exit: the loop is entered once and never
    ;; completes, and its body is walked in a block nothing reaches.
    [diverged? : bool false]
    (try
      (normalize-terminate!
        state
        block
        (own.OwnershipTerminator.Goto
          (normalize-block-id (& state) condition-block))))
    (let
      [condition : NormalizeValue
        (try
          (normalize-walk!
            state
            store
            lease
            (normalize-child-id node 0)
            condition-block
            depth))]
      (set! diverged? (= condition.type 13))
      (unless
        (and
          (or diverged? (= condition.type 1))
          (=
            node.type
            (if diverged?
              13
              0)))
        (return (NormalizeValueResult.Err (normalize-type-error))))
      (unless
        diverged?
        (try
          (normalize-terminate!
            state
            condition.block
            (own.OwnershipTerminator.Branch
              (normalize-place-id (& state) condition.place)
              (normalize-block-id (& state) body-block)
              (normalize-block-id (& state) exit-block))))))
    (let
      [saved-break : i64 state.break-target]
      [saved-continue : i64 state.continue-target]
      (set! state.break-target exit-block)
      (set! state.continue-target condition-block)
      (set! state.loop-depth (+ state.loop-depth 1))
      (let
        [result : NormalizeValueResult
          (normalize-walk!
            state
            store
            lease
            (normalize-child-id node 1)
            body-block
            depth)]
        ;; Restore even when a child fails; no surrounding scope receives
        ;; the abandoned loop's targets during diagnostic unwinding.
        (set! state.break-target saved-break)
        (set! state.continue-target saved-continue)
        (set! state.loop-depth (- state.loop-depth 1))
        (match result
          [(NormalizeValueResult.Err failure)
            (return (NormalizeValueResult.Err failure))]
          [(NormalizeValueResult.Ok body)
            (unless
              (or (= body.type 0) (= body.type 13))
              (return (NormalizeValueResult.Err (normalize-type-error))))
            (when
              (>= body.block 0)
              (try
                (normalize-terminate!
                  state
                  body.block
                  (own.OwnershipTerminator.Goto
                    (normalize-block-id (& state) condition-block)))))])))
    (if diverged?
      (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))
      (normalize-value! state exit-block 0 (& node.source)))))

(define (normalize-loop-control!
  [state : (&mut state NormalizeState)]
  [node : (& node NormalizeNode)]
  [block : i64]
  [target : i64]
  ;; 2 a break, 3 a continue (see `OwnershipObligationDiagnostic`).
  [exit : i64]) : NormalizeValueResult
  (unless
    (= node.type 13)
    (return (NormalizeValueResult.Err (normalize-type-error))))
  (when
    (< target 0)
    (return
      (NormalizeValueResult.Err
        (OwnershipNormalizeFailure.Structural
          "ownership normalization: loop control outside scalar while body"))))
  (try
    (normalize-exit-owners!
      state
      block
      (normalize-loop-owners (& state))
      exit
      (& node.source)))
  (try
    (normalize-terminate!
      state
      block
      (own.OwnershipTerminator.Goto (normalize-block-id (& state) target))))
  (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1)))

;; Walks a child whose value `context` consumes (`move-context`), restoring the
;; enclosing context after it.
(define (normalize-walk-in-context!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [block : i64]
  [depth : i64]
  [context : i64]) : NormalizeValueResult
  (let
    [saved : i64 state.move-context]
    (set! state.move-context context)
    (match (normalize-walk! state store lease id block depth)
      [(NormalizeValueResult.Ok value)
        (set! state.move-context saved)
        (NormalizeValueResult.Ok value)]
      [(NormalizeValueResult.Err failure) (NormalizeValueResult.Err failure)])))

(define (normalize-return!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]
  ;; A generated return propagating a `try` failure.
  [propagates? : bool]) : NormalizeValueResult
  (let
    [operands : (__tl_dyn-array own.OwnershipPlaceId)
      (__tl_make-array own.OwnershipPlaceId 0)]
    [active : i64 block]
    (unless
      (= node.type 13)
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (try (normalize-charge! state 2 2 0))
    (if (= (array-length node.children) 0)
      (unless
        (= state.return-type 0)
        (return (NormalizeValueResult.Err (normalize-type-error))))
      (let
        [value : NormalizeValue
          (try
            (normalize-walk-in-context!
              state
              store
              lease
              (normalize-child-id node 0)
              block
              depth
              4))]
        (unless
          (or (= value.type 13) (= value.type state.return-type))
          (return (NormalizeValueResult.Err (normalize-type-error))))
        (set! active value.block)
        (when
          (>= active 0)
          (begin
            ;; Returning a value moved out of an owner discharges it.
            (try
              (normalize-obligation-consume!
                state
                value.place
                true
                (& node.source)))
            (normalize-i64s-push! (&mut state.return-places) value.place)
            (__tl_array-push!
              operands
              (normalize-place-id (& state) value.place))))))
    (when
      (>= active 0)
      (try
        (normalize-exit-owners!
          state
          active
          0
          (if propagates?
            4
            1)
          (& node.source))))
    (when
      (>= active 0)
      (try
        (normalize-terminate!
          state
          active
          (own.OwnershipTerminator.Return (own.OwnershipPlaceIds operands)))))
    (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))))

(define (normalize-bind-write!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [binder : typed.TypedBinderId]
  [assign? : bool]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [dest : i64 (try (normalize-binder! state store lease binder))]
    [type : i64 (array-ref state.body.places dest).type.index]
    [_definition : unit
      (if assign?
        unit
        (try (normalize-initializer! state dest)))]
    [value : NormalizeValue
      (try
        (normalize-walk-in-context!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth
          (if assign?
            0
            1)))]
    (unless
      (and
        (=
          node.type
          (if (= value.type 13)
            13
            0))
        (or (= value.type 13) (= value.type type)))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (if (= value.type 13)
      (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))
      (begin
        (unless
          assign?
          (try
            (normalize-emit!
              state
              value.block
              ;; This is the unique static Copy declaration, already checked
              ;; above. Loop execution may reuse its ordinary scalar storage.
              (own.OwnershipOperation.Assign
                (normalize-place-id (& state) dest))
              (& node.source))))
        ;; A Copy destination is always initialized. A move-only one may be
        ;; empty after a move; assignment reinitializes it.
        (when
          (and assign? (normalize-copy-type? (& state) type))
          (try
            (normalize-emit-init-check! state value.block dest (& node.source))))
        (when
          (and (not assign?) (!= (normalize-reference-kind (& state) dest) 0))
          (let
            [loan : i64 (normalize-direct-origin (& state) value.place)]
            (when
              (>= loan 0)
              (begin
                (__tl_array-push! state.local-referents dest)
                (__tl_array-push! state.local-referent-loans loan)))))
        ;; Reassigning an initialized cleanup owner would lose its cleanup.
        (when
          (and assign? (normalize-cleanup-type? (& state) type))
          (try
            (normalize-overwrite-check! state value.block dest (& node.source))))
        ;; Moving an owner's value into another owner transfers its
        ;; obligation; into any other binder loses it.
        (try
          (normalize-obligation-consume!
            state
            value.place
            (normalize-cleanup-owner? (normalize-binder-owner (& state) dest))
            (& node.source)))
        (try
          (normalize-transfer!
            state
            value.block
            value.place
            dest
            (& node.source)))
        (when
          (and
            (not assign?)
            (or
              (normalize-cleanup-owner? (normalize-binder-owner (& state) dest))
              (= (normalize-binder-owner (& state) dest) 6)))
          (try
            (normalize-owner-bind!
              state
              value.block
              dest
              (normalize-binder-owner (& state) dest)
              (& node.source))))
        (normalize-value! state value.block 0 (& node.source))))))

;; `normalize-argument!` for an argument `context` consumes (`move-context`).
(define (normalize-argument-in-context!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [block : i64]
  [depth : i64]
  [call? : bool]
  [context : i64]) : NormalizeValueResult
  (let
    [saved : i64 state.move-context]
    (set! state.move-context context)
    (match (normalize-argument! state store lease id block depth call?)
      [(NormalizeValueResult.Ok value)
        (set! state.move-context saved)
        (NormalizeValueResult.Ok value)]
      [(NormalizeValueResult.Err failure) (NormalizeValueResult.Err failure)])))

;; A call argument that reads a mutable-reference binder reborrows it: the call
;; receives a fresh exclusive child loan of the binder's loan, and the binder
;; stays usable afterwards (implicit mutable reborrow, #8179). Any other
;; argument is an ordinary value operand.
(define (normalize-argument!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [block : i64]
  [depth : i64]
  [call? : bool]) : NormalizeValueResult
  (let
    [shared? : bool state.shared-receiver]
    [_cleared : unit (set! state.shared-receiver false)]
    [reserve? : bool false]
    [binder : NormalizeBinderLookup
      (if call?
        (match (typed.typed-occurrence-get! store lease id)
          [(typed.TypedNodeResult.Ok view)
            (match (& view.operation)
              [(typed.TypedOperation.Read read)
                (NormalizeBinderLookup.Some
                  (typed.TypedBinderId
                    (typed.typed-handle-copy (& read.handle))))]
              [(typed.TypedOperation.Borrow true)
                (set! reserve? true)
                NormalizeBinderLookup.No]
              [_ NormalizeBinderLookup.No])]
          [(typed.TypedNodeResult.Err error)
            (return
              (NormalizeValueResult.Err (OwnershipNormalizeFailure.Typed error)))])
        NormalizeBinderLookup.No)]
    (if reserve?
      (normalize-reserve-borrow! state store lease id block depth)
      (match binder
        [(NormalizeBinderLookup.No)
          (normalize-walk! state store lease id block depth)]
        [(NormalizeBinderLookup.Some found)
          (let
            [place : i64 (try (normalize-binder! state store lease found))]
            (cond
              [(!= (normalize-reference-kind (& state) place) 2)
                (normalize-walk! state store lease id block depth)]
              [(normalize-direct-referent? (& state) place)
                (normalize-reborrow! state store lease id place block shared?)]
              [else
                (normalize-referent-reborrow!
                  state
                  store
                  lease
                  id
                  found
                  place
                  block
                  shared?)]))]))))

;; A reference parameter or a local reference initialized from one borrow:
;; its reborrows are children of that known loan.
(define (normalize-direct-referent?
  [state : (& state NormalizeState)]
  [place : i64]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (< index (array-length state.referent-binders))
      (when
        (= (array-ref state.referent-binders index) place)
        (set! found true))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index (array-length state.local-referents))
      (when (= (array-ref state.local-referents index) place) (set! found true))
      (set! index (+ index 1)))
    found))

;; An implicit reborrow of any other mutable-reference binder (one bound by a
;; pattern, returned by a call or read from a field): a two-phase mutable
;; borrow of its referent, an opaque place reached through the reference, so
;; the reborrow keeps the reference's loans live without a known parent.
(define (normalize-referent-reborrow!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [binder : typed.TypedBinderId]
  [place : i64]
  [block : i64]
  [shared? : bool]) : NormalizeValueResult
  (try (normalize-charge! state 1 1 0))
  (let
    [node : NormalizeNode (try (normalize-node! state store lease id))]
    [active : i64
      (if (< block 0)
        (try (normalize-block! state (& node.source)))
        block)]
    [referent-type : i64
      (try (normalize-referent-type! state store lease binder))]
    [route : NormalizePlaceRoute (NormalizePlaceRoute place -1 -1 false false)]
    [_form : unit (set! state.form-block active)]
    [referent : NormalizePlaceRoute
      (if (> referent-type 0)
        (try (normalize-opaque-referent! state (& route) referent-type))
        (NormalizePlaceRoute -1 -1 -1 false false))]
    [_formed : unit (set! state.form-block -1)]
    (unless
      (and (= (array-length node.children) 0) (>= referent.place 0))
      (return
        (NormalizeValueResult.Err
          (OwnershipNormalizeFailure.Unsupported
            "ownership normalization: reborrow of an opaque reference"))))
    (let
      [value : NormalizeValue
        (try
          (normalize-reserve-place!
            state
            (& node)
            (NormalizeValue referent-type referent.place active)
            referent.loan
            referent.binder
            shared?))]
      (try (normalize-retain-node! state node value.place))
      (NormalizeValueResult.Ok value))))

;; A two-phase `(&mut place)` call argument: a shared reservation loan holds
;; the place from the argument's position, so later arguments may read it or
;; borrow it shared for their own evaluation, but cannot move, write or
;; mutably borrow it. The call activates the exclusive loan
;; (`normalize-activate-reservations!`).
(define (normalize-reserve-borrow!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (try (normalize-charge! state 1 1 0))
  (let
    [node : NormalizeNode (try (normalize-node! state store lease id))]
    [active : i64
      (if (< block 0)
        (try (normalize-block! state (& node.source)))
        block)]
    [value : NormalizeValue
      (try (normalize-reserve-emit! state store lease (& node) active depth))]
    (try (normalize-retain-node! state node value.place))
    (NormalizeValueResult.Ok value)))

(define (normalize-reserve-emit!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [borrowed : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    (unless
      (= (array-length node.children) 1)
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (normalize-reserve-place!
      state
      node
      borrowed
      state.formed-loan
      state.formed-binder
      false)))

;; Reserve a two-phase mutable borrow of the formed place `borrowed`, reached
;; through `parent` (an entry, local or opaque referent loan, or -1) and the
;; reference binder `via` (or -1).
(define (normalize-reserve-place!
  [state : (&mut state NormalizeState)]
  [node : (& node NormalizeNode)]
  [borrowed : NormalizeValue]
  [parent : i64]
  [via : i64]
  [shared? : bool]) : NormalizeValueResult
  (let
    [result : i64
      (try (normalize-local! state node.type false (& node.source)))]
    [loan-source : own.OwnershipSource
      (try (normalize-source-copy! state (& node.source)))]
    [kept-source : own.OwnershipSource
      (try (normalize-source-copy! state (& node.source)))]
    (unless
      (and
        (< node.type (array-length state.type-references))
        (= (array-ref state.type-references node.type) 2))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (unless
      shared?
      (try
        (normalize-exclusive-ok (& state) parent borrowed.place (& node.source))))
    (let
      ;; Behind an opaque referent the reference is read here (its own loans
      ;; are used) and the referent is reserved and activated like an owned
      ;; place, so reads through the same reference before the activation
      ;; do not conflict. The formed referent loan is issued unused.
      [opaque? : bool (normalize-deferred-loan? (& state) parent)]
      [reserve-parent : i64
        (if opaque?
          (begin
            (try (normalize-issue-deferred! state borrowed.block parent false))
            (try
              (normalize-emit!
                state
                borrowed.block
                (own.OwnershipOperation.Read (normalize-place-id (& state) via))
                (& node.source)))
            -1)
          parent)]
      [loan : i64 state.loan-count]
      (try (normalize-charge! state 1 1 0))
      (__tl_array-push! state.reservation-loans loan)
      (normalize-loan-append!
        state
        (own.OwnershipLoan
          (normalize-place-id (& state) borrowed.place)
          own.OwnershipLoanKind.Shared
          (normalize-loan-origin (& state) reserve-parent)
          loan-source))
      (try
        (normalize-borrow-emit!
          state
          borrowed.block
          loan
          reserve-parent
          via
          (& node.source)))
      ;; The activated reborrow keeps the reference's own loans live too.
      (when (>= via 0) (try (normalize-note-outlives! state via result)))
      (normalize-reserve-push!
        state
        loan
        borrowed.place
        result
        kept-source
        -1
        reserve-parent
        shared?))
    (NormalizeValueResult.Ok (NormalizeValue node.type result borrowed.block))))

;; Record a pending activation for the enclosing call.
(define (normalize-reserve-push!
  [state : (&mut state NormalizeState)]
  [loan : i64]
  [place : i64]
  [result : i64]
  [source : own.OwnershipSource]
  [child : i64]
  [parent : i64]
  [shared? : bool]) : unit
  (if (< state.reserved-count (array-length state.reserved-loans))
    (begin
      (set! (array-ref state.reserved-loans state.reserved-count) loan)
      (set! (array-ref state.reserved-places state.reserved-count) place)
      (set! (array-ref state.reserved-results state.reserved-count) result)
      (set! (array-ref state.reserved-sources state.reserved-count) source)
      (set! (array-ref state.reserved-children state.reserved-count) child)
      (set! (array-ref state.reserved-parents state.reserved-count) parent)
      (set! (array-ref state.reserved-shared state.reserved-count) shared?))
    (begin
      (__tl_array-push! state.reserved-loans loan)
      (__tl_array-push! state.reserved-places place)
      (__tl_array-push! state.reserved-results result)
      (__tl_array-push! state.reserved-sources source)
      (__tl_array-push! state.reserved-children child)
      (__tl_array-push! state.reserved-parents parent)
      (__tl_array-push! state.reserved-shared shared?)))
  (set! state.reserved-count (+ state.reserved-count 1)))

;; Activation: each reservation is used once more, then its exclusive loan is
;; issued after every argument was evaluated; the reference temporary holds it.
(define (normalize-activate-reservations!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [mark : i64]) : NormalizeUnit
  (let
    [index : i64 mark]
    (while (< index state.reserved-count)
      (let
        [reservation : i64 (array-ref state.reserved-loans index)]
        [place : i64 (array-ref state.reserved-places index)]
        [result : i64 (array-ref state.reserved-results index)]
        [source : own.OwnershipSource
          (own.ownership-source-copy
            (& (array-ref state.reserved-sources index)))]
        [loan : i64 state.loan-count]
        [loan-source : own.OwnershipSource
          (own.ownership-source-copy (& source))]
        [child : i64 (array-ref state.reserved-children index)]
        (if (>= child 0)
          ;; An implicit reborrow takes its child loan at the boundary; the
          ;; binder is read there and its loan is the solved parent.
          (begin
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.UseLoan
                  (own.OwnershipLoanId
                    (typed.typed-body-copy (& state.body.id))
                    reservation))
                (& source)))
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.Read
                  (normalize-place-id (& state) place))
                (& source)))
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.Reborrow
                  (own.OwnershipLoanId
                    (typed.typed-body-copy (& state.body.id))
                    child))
                (& source)))
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.Assign
                  (normalize-place-id (& state) result))
                (& source)))
            (try (normalize-note-origin! state result child))
            (set! index (+ index 1)))
          (begin
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.UseLoan
                  (own.OwnershipLoanId
                    (typed.typed-body-copy (& state.body.id))
                    reservation))
                (& source)))
            ;; An opaque referent's exclusive loan is issued at activation.
            (try
              (normalize-issue-deferred!
                state
                block
                (array-ref state.reserved-parents index)
                true))
            (try (normalize-charge! state 1 1 0))
            (normalize-loan-append!
              state
              (own.OwnershipLoan
                (normalize-place-id (& state) place)
                (if (array-ref state.reserved-shared index)
                  own.OwnershipLoanKind.Shared
                  own.OwnershipLoanKind.Exclusive)
                (normalize-loan-origin
                  (& state)
                  (array-ref state.reserved-parents index))
                loan-source))
            (try
              (normalize-emit!
                state
                block
                (if (< (array-ref state.reserved-parents index) 0)
                  (own.OwnershipOperation.Borrow
                    (own.OwnershipLoanId
                      (typed.typed-body-copy (& state.body.id))
                      loan))
                  (own.OwnershipOperation.Reborrow
                    (own.OwnershipLoanId
                      (typed.typed-body-copy (& state.body.id))
                      loan)))
                (& source)))
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.Assign
                  (normalize-place-id (& state) result))
                (& source)))
            (try (normalize-note-origin! state result loan))
            (try (normalize-note-contents! state place result))
            ;; The borrowed place keeps holding the loans of its contents,
            ;; which the reference reaches through it: they are used through
            ;; that place here, so their demands continue through it until
            ;; it is overwritten (`ownership-loan-liveness`).
            (try
              (normalize-note-use!
                state
                block
                (array-ref state.instruction-counts block)
                place))
            (set! index (+ index 1))))))
    (set! state.reserved-count mark)
    (NormalizeUnit.Ok unit)))

(defenum NormalizeBinderLookup
  (Some typed.TypedBinderId)
  (No))

(define (normalize-reborrow!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [place : i64]
  [block : i64]
  [shared? : bool]) : NormalizeValueResult
  (try (normalize-charge! state 1 1 0))
  (let
    [node : NormalizeNode (try (normalize-node! state store lease id))]
    [active : i64
      (if (< block 0)
        (try (normalize-block! state (& node.source)))
        block)]
    [value : NormalizeValue
      (try (normalize-reborrow-emit! state (& node) place active shared?))]
    (try (normalize-retain-node! state node value.place))
    (NormalizeValueResult.Ok value)))

(define (normalize-reborrow-emit!
  [state : (&mut state NormalizeState)]
  [node : (& node NormalizeNode)]
  [place : i64]
  [active : i64]
  [shared? : bool]) : NormalizeValueResult
  (let
    [loan : i64 state.loan-count]
    [loan-source : own.OwnershipSource
      (try (normalize-source-copy! state (& node.source)))]
    [kept-source : own.OwnershipSource
      (try (normalize-source-copy! state (& node.source)))]
    [result : i64
      (try (normalize-local! state node.type false (& node.source)))]
    (unless
      (and
        (= (array-length node.children) 0)
        (= (array-ref state.body.places place).type.index node.type))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    ;; The child loan's place and parent are patched to the binder's single
    ;; solved origin; it is issued when the call activates its arguments.
    (try (normalize-charge! state 1 1 0))
    (normalize-loan-append!
      state
      (own.OwnershipLoan
        (normalize-place-id (& state) place)
        (if shared?
          own.OwnershipLoanKind.Shared
          own.OwnershipLoanKind.Exclusive)
        (own.OwnershipLoanOrigin.Parent
          (own.OwnershipLoanId (typed.typed-body-copy (& state.body.id)) loan))
        loan-source))
    (__tl_array-push! state.reborrow-loans loan)
    (__tl_array-push! state.reborrow-places place)
    (let
      [reservation : i64 state.loan-count]
      [reservation-source : own.OwnershipSource
        (try (normalize-source-copy! state (& node.source)))]
      (try (normalize-charge! state 1 1 0))
      (__tl_array-push! state.reservation-loans reservation)
      (normalize-loan-append!
        state
        (own.OwnershipLoan
          (normalize-place-id (& state) place)
          own.OwnershipLoanKind.Shared
          own.OwnershipLoanOrigin.Direct
          reservation-source))
      (try
        (normalize-emit!
          state
          active
          (own.OwnershipOperation.Borrow
            (own.OwnershipLoanId
              (typed.typed-body-copy (& state.body.id))
              reservation))
          (& node.source)))
      ;; The implicit reborrow keeps the binder's own loans live too.
      (try (normalize-note-outlives! state place result))
      (normalize-reserve-push!
        state
        reservation
        place
        result
        kept-source
        loan
        -1
        shared?))
    (NormalizeValueResult.Ok (NormalizeValue node.type result active))))

;; A whole binder place evaluates nothing; its value is the binder's own place.
;; Index or projection paths are not represented yet.
;; --- Places -----------------------------------------------------------------
;; One step of a typed place, copied out of the store's view.
(defenum NormalizePlaceStep
  (Root typed.TypedBinderId)
  (Projection typed.TypedPlaceId typed.TypedProjectionId))

(defenum NormalizePlaceStepResult
  (Ok NormalizePlaceStep)
  (Err OwnershipNormalizeFailure))

;; A projection as the normalizer models it: a field ordinal, -1 for the
;; referent of a reference, -3 for an array element, or -2 for a kind outside
;; the subset.
(defstruct NormalizeProjectionStep
  (ordinal i64)
  (result typed.TypedTypeId)
  (container i64))

(defenum NormalizeProjectionStepResult
  (Ok NormalizeProjectionStep)
  (Err OwnershipNormalizeFailure))

;; A formed place and how it is reached: through the entry loan of the
;; reference parameter `binder` (its referent's places), or owned (-1). An
;; indexed route stands for a part the checker cannot name: every access of
;; it is an access of the whole place `place` (an array's elements, or an owned
;; box's contents, with their own fields inside). A boxed route reaches only
;; box contents and fields, so moving out of it consumes the box.
(defstruct NormalizePlaceRoute
  (place i64)
  (loan i64)
  (binder i64)
  (indexed bool)
  (boxed bool))

(defenum NormalizeRouteResult
  (Ok NormalizePlaceRoute)
  (Err OwnershipNormalizeFailure))

(define (normalize-place-step!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedPlaceId]) : NormalizePlaceStepResult
  (match (typed.typed-place-get! store lease id)
    [(typed.TypedPlaceView.Ok row)
      (NormalizePlaceStepResult.Ok
        (match (& row.kind)
          [(typed.TypedPlaceKind.Root binder)
            (NormalizePlaceStep.Root
              (typed.TypedBinderId (typed.typed-handle-copy (& binder.handle))))]
          [(typed.TypedPlaceKind.Projection parent step)
            (NormalizePlaceStep.Projection
              (typed.TypedPlaceId (typed.typed-handle-copy (& parent.handle)))
              (typed.TypedProjectionId
                (typed.typed-handle-copy (& step.handle))))]))]
    [(typed.TypedPlaceView.Err error)
      (NormalizePlaceStepResult.Err (OwnershipNormalizeFailure.Typed error))]))

(define (normalize-projection-step!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedProjectionId]) : NormalizeProjectionStepResult
  (match (typed.typed-projection-get! store lease id)
    [(typed.TypedProjectionView.Ok row)
      (NormalizeProjectionStepResult.Ok
        (NormalizeProjectionStep
          (match (& row.kind)
            [(typed.TypedProjectionKind.StructField _ ordinal) ordinal]
            [(typed.TypedProjectionKind.TupleElement ordinal) ordinal]
            [(typed.TypedProjectionKind.Payload _ ordinal) ordinal]
            [(typed.TypedProjectionKind.Deref) -1]
            [(typed.TypedProjectionKind.ArrayElement) -3]
            ;; A pattern's literal-index element is its own place.
            [(typed.TypedProjectionKind.FixedArrayElement ordinal) ordinal]
            [_ -2])
          (typed.TypedTypeId
            (typed.typed-handle-copy (& row.result-type.handle)))
          row.container-type.handle.index))]
    [(typed.TypedProjectionView.Err error)
      (NormalizeProjectionStepResult.Err
        (OwnershipNormalizeFailure.Typed error))]))

;; Marks the classes this body takes fields of: only they get a product shape.
(define (normalize-projected!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]) : NormalizeUnit
  (let
    ;; The store enters the normalizer here, before any of its records is
    ;; read: check it in full, its table shape included. Later accesses
    ;; recheck only the events that can invalidate that check.
    [count : i64
      (match (match (typed.typed-store-admit! store lease)
        [(typed.TypedResult.Ok _) (typed.typed-place-count! store lease)]
        [(typed.TypedResult.Err error) (typed.TypedCountResult.Err error)])
        [(typed.TypedCountResult.Ok value) value]
        [(typed.TypedCountResult.Err error)
          (return (NormalizeUnit.Err (OwnershipNormalizeFailure.Typed error)))])]
    [index : i64 0]
    (while (< index count)
      (let
        [id : typed.TypedPlaceId
          (match (typed.typed-place-at! store lease index)
            [(typed.TypedPlaceResult.Ok value) value]
            [(typed.TypedPlaceResult.Err error)
              (return
                (NormalizeUnit.Err (OwnershipNormalizeFailure.Typed error)))])]
        (try (normalize-charge! state 0 1 0))
        (match (try (normalize-place-step! store lease id))
          [(NormalizePlaceStep.Projection _ projection)
            (let
              [step : NormalizeProjectionStep
                (try (normalize-projection-step! store lease projection))]
              (when
                (and
                  (>= step.ordinal 0)
                  (< step.container (array-length state.classes))
                  (>= (array-ref state.classes step.container).key 0))
                (let
                  [key : i64 (array-ref state.classes step.container).key]
                  ;; A view's fields are its referent's (reached through
                  ;; its loan): that struct is projected too.
                  [referent : i64
                    (array-ref state.classes step.container).referent]
                  [referent-key : i64
                    (if (and
                      (> (array-ref state.classes step.container).reference 0)
                      (>= referent 0)
                      (< referent (array-length state.classes)))
                      (array-ref state.classes referent).key
                      -1)]
                  (while (<= (array-length state.projected) key)
                    (__tl_array-push! state.projected false))
                  (set! (array-ref state.projected key) true)
                  (when
                    (>= referent-key 0)
                    (while (<= (array-length state.projected) referent-key)
                      (__tl_array-push! state.projected false))
                    (set! (array-ref state.projected referent-key) true)))))]
          [_ unit])
        (set! index (+ index 1))))
    (NormalizeUnit.Ok unit)))

;; The place of field `ordinal` of a product place, or -1.
(define (normalize-field-place
  [state : (& state NormalizeState)]
  [parent : i64]
  [ordinal : i64]) : i64
  (let
    [index : i64 (+ parent 1)]
    [found : i64 -1]
    (while (and (< found 0) (< index state.place-count))
      (begin
        (match (& (array-ref state.body.places index).projection)
          [(own.OwnershipProjection.Field owner number)
            (when
              (and (= owner.index parent) (= number ordinal))
              (set! found index))]
          [_ unit])
        (set! index (+ index 1))))
    found))

;; Whether typed type `container` is an owned box (its class has contents).
(define (normalize-box-class?
  [state : (& state NormalizeState)]
  [container : i64]) : bool
  (and
    (>= container 0)
    (< container (array-length state.classes))
    (= (array-ref state.classes container).reference 0)
    (>= (array-ref state.classes container).referent 0)))

;; The referent of a reference parameter, reached through its entry loan, or
;; of a local reference binder holding exactly one loan (`local-referents`),
;; reached through that loan. Any other reference's referent is outside the
;; place subset (place -1).
(define (normalize-deref-route
  [state : (&mut state NormalizeState)]
  [route : (& route NormalizePlaceRoute)]) : NormalizePlaceRoute
  (let
    [index : i64 0]
    [found : NormalizePlaceRoute (NormalizePlaceRoute -1 -1 -1 false false)]
    (when
      (< route.loan 0)
      (while (< index (array-length state.referent-binders))
        (when
          (= (array-ref state.referent-binders index) route.place)
          (set!
            found
            (NormalizePlaceRoute
              (array-ref state.referent-places index)
              (array-ref state.parameter-loans index)
              route.place
              false
              false)))
        (set! index (+ index 1)))
      (when
        (< found.place 0)
        (let
          [loan : i64 (normalize-local-referent-loan (& state) route.place)]
          (when
            (>= loan 0)
            (begin
              (__tl_array-push! state.deref-places route.place)
              (__tl_array-push! state.deref-loans loan)
              (set!
                found
                (NormalizePlaceRoute
                  (array-ref state.body.loans loan).place.index
                  loan
                  route.place
                  false
                  false)))))))
    found))

;; The referent of any other reference place, reached while a place is
;; formed: one synthetic initialized place per reference, borrowed (shared or
;; exclusive like the reference) where the place is formed. The access also
;; reads the reference, which uses every loan it may hold; this loan only
;; orders accesses through the reference, and nothing moves out of it.
(define (normalize-opaque-referent!
  [state : (&mut state NormalizeState)]
  [route : (& route NormalizePlaceRoute)]
  [type : i64]) : NormalizeRouteResult
  (normalize-opaque-referent-of!
    state
    route
    type
    (if (and (>= route.place 0) (not route.indexed))
      (normalize-reference-kind (& state) route.place)
      0)))

;; The referent of a reference of kind `kind` (1 shared, 2 mutable) held at
;; `route`: a reference place, or an unnamed element of the array `route`
;; reaches (all its elements' referents share one synthetic place, and the
;; access reads the whole array, using every loan it holds). A mutable
;; reference reached through a shared loan grants shared access only (Rust
;; E0596/E0594 through `& &mut T`): its referent's loan is shared.
(define (normalize-opaque-referent-of!
  [state : (&mut state NormalizeState)]
  [route : (& route NormalizePlaceRoute)]
  [type : i64]
  [reference-kind : i64]) : NormalizeRouteResult
  (let
    [none : NormalizePlaceRoute (NormalizePlaceRoute -1 -1 -1 false false)]
    [kind : i64
      (if (and
        (= reference-kind 2)
        (>= route.loan 0)
        (not
          (own.ownership-loan-exclusive?
            (& (array-ref state.body.loans route.loan)))))
        1
        reference-kind)]
    (if (or (< state.form-block 0) (= kind 0) (< type 0))
      (NormalizeRouteResult.Ok none)
      (let
        [index : i64 0]
        [place : i64 -1]
        (while (< index (array-length state.opaque-binders))
          (when
            (= (array-ref state.opaque-binders index) route.place)
            (set! place (array-ref state.opaque-places index)))
          (set! index (+ index 1)))
        (let
          [source : own.OwnershipSource
            (try (normalize-place-source-copy! state route.place))]
          [referent : i64
            (if (>= place 0)
              place
              (let
                [fresh : i64
                  (try (normalize-local! state type true (& source)))]
                (__tl_array-push! state.opaque-binders route.place)
                (__tl_array-push! state.opaque-places fresh)
                (normalize-note-deref! state fresh route.place)
                fresh))]
          [loan : i64 state.loan-count]
          (unless
            (= (array-ref state.body.places referent).type.index type)
            (return (NormalizeRouteResult.Ok none)))
          (try (normalize-charge! state 1 1 0))
          (normalize-loan-append!
            state
            (own.OwnershipLoan
              (normalize-place-id (& state) referent)
              (if (= kind 2)
                own.OwnershipLoanKind.Exclusive
                own.OwnershipLoanKind.Shared)
              own.OwnershipLoanOrigin.Direct
              source))
          (__tl_array-push! state.deferred-loans loan)
          ;; A reference behind another reference is read through that
          ;; reference's loan here (its own loans are used at this read);
          ;; accesses then use the outer reference binder.
          (if (< route.loan 0)
            (NormalizeRouteResult.Ok
              (NormalizePlaceRoute referent loan route.place false false))
            (let
              [read-source : own.OwnershipSource
                (try (normalize-loan-source-copy! state loan))]
              (try
                (normalize-emit!
                  state
                  state.form-block
                  (own.OwnershipOperation.AccessThrough
                    (own.OwnershipLoanId
                      (typed.typed-body-copy (& state.body.id))
                      route.loan)
                    (normalize-place-id (& state) route.place)
                    own.OwnershipAccess.Read)
                  (& read-source)))
              (try
                (normalize-note-use!
                  state
                  state.form-block
                  (- (array-ref state.instruction-counts state.form-block) 1)
                  route.place))
              (NormalizeRouteResult.Ok
                (NormalizePlaceRoute referent loan route.binder false false)))))))))

;; The loan a local reference binder was initialized from, or -1.
(define (normalize-local-referent-loan
  [state : (& state NormalizeState)]
  [place : i64]) : i64
  (let
    [index : i64 (- (array-length state.local-referents) 1)]
    [found : i64 -1]
    (while (and (< found 0) (>= index 0))
      (when
        (= (array-ref state.local-referents index) place)
        (set! found (array-ref state.local-referent-loans index)))
      (set! index (- index 1)))
    found))

;; The single loan noted directly on a reference value's place, or -1.
(define (normalize-direct-origin
  [state : (& state NormalizeState)]
  [place : i64]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    [count : i64 0]
    (while (< index state.origin-count)
      (when
        (= (array-ref state.origin-places index) place)
        (set! found (array-ref state.origin-loans index))
        (set! count (+ count 1)))
      (set! index (+ index 1)))
    (if (= count 1)
      found
      -1)))

;; A fixed array, through region tags.
;; 1 when typed type `container` is a box, whatever the loans its contents
;; hold, else 0.
(define (normalize-box-type!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [container : i64]) : NormalizeInt
  (if (< container 0)
    (NormalizeInt.Ok 0)
    (match (typed.typed-type-value-at! store lease container)
      [(typed.TypedTypeValueResult.Ok value)
        (NormalizeInt.Ok
          (if (normalize-box-ast-type? (& value))
            1
            0))]
      [(typed.TypedTypeValueResult.Err error)
        (NormalizeInt.Err (OwnershipNormalizeFailure.Typed error))])))

(define (normalize-box-ast-type? [ty : (& ty ast.AstType)]) : bool
  (match ty
    [(ast.AstType.Box _) true]
    [(ast.AstType.Region _ inner)
      (let
        [inner-ty : ast.AstType (ast.ty-node-get inner)]
        (normalize-box-ast-type? (& inner-ty)))]
    [_ false]))

(define (normalize-fixed-array-type? [ty : (& ty ast.AstType)]) : bool
  (match ty
    [(ast.AstType.Array _ _) true]
    [(ast.AstType.Region _ inner)
      (let
        [inner-ty : ast.AstType (ast.ty-node-get inner)]
        (normalize-fixed-array-type? (& inner-ty)))]
    [_ false]))

(define (normalize-place!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedPlaceId]
  [depth : i64]) : NormalizeRouteResult
  (when
    (> depth state.limits.depth)
    (return (NormalizeRouteResult.Err OwnershipNormalizeFailure.Resource)))
  (try (normalize-charge! state 0 1 0))
  (match (try (normalize-place-step! store lease id))
    [(NormalizePlaceStep.Root binder)
      (NormalizeRouteResult.Ok
        (NormalizePlaceRoute
          (try (normalize-binder! state store lease binder))
          -1
          -1
          false
          false))]
    [(NormalizePlaceStep.Projection parent projection)
      (let
        [route : NormalizePlaceRoute
          (try (normalize-place! state store lease parent (+ depth 1)))]
        [step : NormalizeProjectionStep
          (try (normalize-projection-step! store lease projection))]
        [_fixed : unit
          (when
            (= step.ordinal -3)
            (match (typed.typed-type-value-at! store lease step.container)
              [(typed.TypedTypeValueResult.Ok container)
                (when
                  (normalize-fixed-array-type? (& container))
                  (set! state.walk-fixed true))]
              [(typed.TypedTypeValueResult.Err _) unit]))]
        [type : i64 (try (normalize-type! state store lease step.result))]
        ;; A box holding references is classed as a holder of their loans,
        ;; yet its contents are still the box's own: they are reached through
        ;; the whole box and hold its loans, as a reference's referent does
        ;; not.
        [box-step? : bool
          (and
            (= step.ordinal -1)
            (or
              (normalize-box-class? (& state) step.container)
              (= (try (normalize-box-type! store lease step.container)) 1)))]
        [target : NormalizePlaceRoute
          (cond
            ;; Below an unnamed part only referents are out of reach; an
            ;; element below it is no longer box contents alone.
            ;; A reference held in an unnamed element is dereferenced
            ;; opaquely, through the whole array.
            [(and route.indexed (= step.ordinal -1) (not box-step?))
              (let
                [kind : i64
                  (if (and
                    (>= step.container 0)
                    (< step.container (array-length state.classes)))
                    (array-ref state.classes step.container).reference
                    0)]
                (try (normalize-opaque-referent-of! state (& route) type kind)))]
            [route.indexed
              (if (= step.ordinal -2)
                (NormalizePlaceRoute -1 -1 -1 false false)
                (NormalizePlaceRoute
                  route.place
                  route.loan
                  route.binder
                  true
                  (and route.boxed (!= step.ordinal -3))))]
            [box-step?
              (NormalizePlaceRoute
                route.place
                route.loan
                route.binder
                true
                true)]
            [(>= step.ordinal 0)
              (let
                [own : i64
                  (try (normalize-field-place! state route.place step.ordinal))]
                (if (and
                  (!= (array-ref state.body.places own).type.index type)
                  (normalize-view-route? (& state) (& route) step.container))
                  ;; The field of a view (a struct read through a reference)
                  ;; whose own part is a view of it: the referent's field,
                  ;; reached through the view's loan as a dereference is.
                  (let
                    [referent-type : i64
                      (try
                        (normalize-class-referent-type!
                          state
                          store
                          lease
                          step.container))]
                    [found : NormalizePlaceRoute
                      (normalize-deref-route state (& route))]
                    ;; The view's loan may hold a larger place (a parameter's
                    ;; whole referent): its part is then reached opaquely.
                    [derefed : NormalizePlaceRoute
                      (if (and
                        (>= found.place 0)
                        (=
                          (array-ref state.body.places found.place).type.index
                          referent-type))
                        found
                        (try
                          (normalize-opaque-referent!
                            state
                            (& route)
                            referent-type)))]
                    (if (< derefed.place 0)
                      (NormalizePlaceRoute -1 -1 -1 false false)
                      (NormalizePlaceRoute
                        (try
                          (normalize-field-place!
                            state
                            derefed.place
                            step.ordinal))
                        derefed.loan
                        derefed.binder
                        false
                        false)))
                  (NormalizePlaceRoute own route.loan route.binder false false)))]
            ;; A reference whose loan holds a larger place (box contents, an
            ;; element) reaches a part of it.
            [(= step.ordinal -1)
              (let
                [found : NormalizePlaceRoute
                  (normalize-deref-route state (& route))]
                [derefed : NormalizePlaceRoute
                  (if (< found.place 0)
                    (try (normalize-opaque-referent! state (& route) type))
                    found)]
                (if (and
                  (>= derefed.place 0)
                  (>= derefed.loan 0)
                  (!=
                    (array-ref state.body.places derefed.place).type.index
                    type))
                  (NormalizePlaceRoute
                    derefed.place
                    derefed.loan
                    derefed.binder
                    true
                    false)
                  derefed))]
            [(= step.ordinal -3)
              (NormalizePlaceRoute
                route.place
                route.loan
                route.binder
                true
                false)]
            [else (NormalizePlaceRoute -1 -1 -1 false false)])]
        (if (or
          (< target.place 0)
          (and
            (not target.indexed)
            (!= (array-ref state.body.places target.place).type.index type)))
          (NormalizeRouteResult.Err
            (OwnershipNormalizeFailure.Unsupported
              "ownership normalization: projection outside the place subset"))
          (begin
            (unless
              target.indexed
              (normalize-note-typed!
                state
                target.place
                step.result.handle.index))
            (NormalizeRouteResult.Ok target))))]))

;; Forming a place evaluates its index children in root-to-leaf order (each a
;; value); the route is left for the consumer, which accesses the place after
;; them.
(define (normalize-form-place!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [place : typed.TypedPlaceId]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [active : i64 block]
    [index : i64 0]
    (while (< index (array-length node.children))
      (let
        [value : NormalizeValue
          (try
            (normalize-walk!
              state
              store
              lease
              (normalize-child-id node index)
              active
              depth))]
        (when
          (< value.block 0)
          (return
            (NormalizeValueResult.Err
              (OwnershipNormalizeFailure.Structural
                "ownership normalization: diverging place index"))))
        (set! active value.block)
        (set! index (+ index 1))))
    (let
      [literal : i64
        (if (= (array-length node.children) 1)
          (try
            (normalize-literal-index!
              state
              store
              lease
              (normalize-child-id node 0)))
          -1)]
      [_form : unit (set! state.form-block active)]
      [_fixed : unit (set! state.walk-fixed false)]
      [route : NormalizePlaceRoute
        (try (normalize-place! state store lease place 0))]
      (set! state.form-block -1)
      (unless
        (or
          route.indexed
          (= (array-ref state.body.places route.place).type.index node.type))
        (return (NormalizeValueResult.Err (normalize-type-error))))
      (set! state.formed-loan route.loan)
      (set! state.formed-binder route.binder)
      (set! state.formed-indexed route.indexed)
      (set! state.formed-boxed route.boxed)
      (set! state.formed-fixed state.walk-fixed)
      (set!
        state.formed-element
        (if (and route.indexed state.walk-fixed)
          literal
          -1))
      (NormalizeValueResult.Ok (NormalizeValue node.type route.place active)))))

;; Taking a place's value: an owned place copies or moves (a field moves out
;; alone); a place behind a reference parameter is only copied, as a read
;; through its entry loan by a use of the reference.
;; Whether the place an occurrence forms is a part of owned box contents (a
;; field, element or payload below the `deref`) rather than the contents
;; themselves: its last projection is not the `deref`.
(define (normalize-box-part-place?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]) : bool
  (let
    [place : NormalizeMaybePlace
      (match (typed.typed-occurrence-get! store lease id)
        [(typed.TypedNodeResult.Ok occurrence)
          (match (& occurrence.operation)
            [(typed.TypedOperation.FormPlace place)
              (NormalizeMaybePlace.Some
                (typed.TypedPlaceId (typed.typed-handle-copy (& place.handle))))]
            [_ NormalizeMaybePlace.No])]
        [(typed.TypedNodeResult.Err _) NormalizeMaybePlace.No])]
    [step : NormalizeMaybeProjection
      (match place
        [(NormalizeMaybePlace.No) NormalizeMaybeProjection.No]
        [(NormalizeMaybePlace.Some place-id)
          (match (typed.typed-place-get! store lease place-id)
            [(typed.TypedPlaceView.Ok row)
              (match (& row.kind)
                [(typed.TypedPlaceKind.Projection _ step)
                  (NormalizeMaybeProjection.Some
                    (typed.TypedProjectionId
                      (typed.typed-handle-copy (& step.handle))))]
                [_ NormalizeMaybeProjection.No])]
            [(typed.TypedPlaceView.Err _) NormalizeMaybeProjection.No])])]
    (match step
      [(NormalizeMaybeProjection.No) false]
      [(NormalizeMaybeProjection.Some step-id)
        (match (typed.typed-projection-get! store lease step-id)
          [(typed.TypedProjectionView.Ok row)
            (match (& row.kind)
              [(typed.TypedProjectionKind.Deref) false]
              [_ true])]
          [(typed.TypedProjectionView.Err _) false])])))

(defenum NormalizeMaybePlace
  (Some typed.TypedPlaceId)
  (No))

(defenum NormalizeMaybeProjection
  (Some typed.TypedProjectionId)
  (No))

(define (normalize-take-place!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [formed : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    [loan : i64 state.formed-loan]
    [binder : i64 state.formed-binder]
    [indexed : bool state.formed-indexed]
    [boxed : bool state.formed-boxed]
    [fixed : bool state.formed-fixed]
    [element : i64 state.formed-element]
    (unless
      (= formed.type node.type)
      (return (NormalizeValueResult.Err (normalize-type-error))))
    ;; Moving owned box contents out consumes the box.
    (when
      (and
        indexed
        boxed
        (< loan 0)
        (not (normalize-copy-type? (& state) node.type)))
      (begin
        ;; An owner-consuming part (one carrying a cleanup obligation) moves
        ;; out of the contents only by destructuring the whole box (a
        ;; pattern); projected out alone it would leave the box partly moved.
        (when
          (and
            (normalize-cleanup-type? (& state) node.type)
            (normalize-box-part-place? store lease (normalize-child-id node 0)))
          (return
            (NormalizeValueResult.Err
              (OwnershipNormalizeFailure.MoveOut
                (OwnershipMoveOutDiagnostic
                  (normalize-binder-name
                    (& state)
                    (normalize-place-root (& state) formed.place))
                  (normalize-place-fields (& state) formed.place)
                  4
                  (try (normalize-source-copy! state (& node.source)))
                  NormalizeMaybeType.No
                  state.move-context)))))
        (try
          (normalize-emit!
            state
            formed.block
            (own.OwnershipOperation.Consume
              (normalize-place-id (& state) formed.place))
            (& node.source)))
        ;; The moved part takes the box's loans with it (a `&mut` or a
        ;; reference holder taken out of a box holding references).
        (let
          [moved : NormalizeValue
            (try
              (normalize-value! state formed.block node.type (& node.source)))]
          (try (normalize-note-flow! state formed.place moved.place))
          (return (NormalizeValueResult.Ok moved)))))
    (if (and (< loan 0) (not indexed))
      (let
        [dest : i64
          (try (normalize-local! state node.type false (& node.source)))]
        (try
          (normalize-transfer!
            state
            formed.block
            formed.place
            dest
            (& node.source)))
        (when
          (and
            (= (normalize-binder-owner (& state) formed.place) 1)
            (not (normalize-copy-type? (& state) node.type)))
          (try
            (normalize-owner-moved!
              state
              formed.block
              formed.place
              dest
              (& node.source))))
        (NormalizeValueResult.Ok (NormalizeValue node.type dest formed.block)))
      ;; Behind a reference or at an unnamed element, a Copy value is read
      ;; from the place that holds it; nothing moves out. A move-only value
      ;; cannot leave such a place (SPEC: array element ownership).
      (begin
        (unless
          (normalize-copy-type? (& state) node.type)
          (return
            (NormalizeValueResult.Err
              (OwnershipNormalizeFailure.MoveOut
                (OwnershipMoveOutDiagnostic
                  (normalize-binder-name
                    (& state)
                    (normalize-place-root (& state) formed.place))
                  (normalize-place-fields (& state) formed.place)
                  ;; A place reached through a reference is borrowed content
                  ;; whatever holds it (E0208, Rust E0507); only an owned
                  ;; container's element is an element move.
                  (cond
                    [(>= loan 0)
                      (match (& (array-ref state.body.loans loan).kind)
                        [(own.OwnershipLoanKind.Exclusive) 2]
                        [_ 1])]
                    ;; A fixed array's element at a runtime index (a literal
                    ;; index in range is an exact path, moved on its own).
                    [(and indexed fixed) 4]
                    [indexed 0]
                    [else 1])
                  (try (normalize-source-copy! state (& node.source)))
                  (match (typed.typed-occurrence-get!
                    store
                    lease
                    (typed.TypedOccurrenceId
                      (typed.typed-handle-copy (& node.handle))))
                    [(typed.TypedNodeResult.Ok occurrence)
                      (NormalizeMaybeType.Some
                        (typed.TypedTypeId
                          (typed.typed-handle-copy (& occurrence.type.handle))))]
                    [(typed.TypedNodeResult.Err _) NormalizeMaybeType.No])
                  state.move-context)))))
        (normalize-element-site!
          state
          formed.block
          formed.place
          (& node.source)
          element)
        (if (< loan 0)
          (try
            (normalize-emit!
              state
              formed.block
              (own.OwnershipOperation.Read
                (normalize-place-id (& state) formed.place))
              (& node.source)))
          (begin
            (try
              (normalize-emit!
                state
                formed.block
                (own.OwnershipOperation.Read
                  (normalize-place-id (& state) binder))
                (& node.source)))
            (try
              (normalize-emit!
                state
                formed.block
                (own.OwnershipOperation.AccessThrough
                  (own.OwnershipLoanId
                    (typed.typed-body-copy (& state.body.id))
                    loan)
                  (normalize-place-id (& state) formed.place)
                  own.OwnershipAccess.Read)
                (& node.source)))))
        (let
          [value : NormalizeValue
            (try
              (normalize-value! state formed.block node.type (& node.source)))]
          ;; A reference read out of a view keeps the view's loans.
          (try (normalize-note-flow! state formed.place value.place))
          (NormalizeValueResult.Ok value))))))

;; Storing into a formed place after evaluating the value: an owned place is
;; overwritten (a move-only one may have been moved out; the store
;; reinitializes it), a place behind a mutable reference is written through
;; its loan and the value moves into the referent. An unnamed part (an
;; element, box contents) is stored through its own forms.
(define (normalize-assign-place!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [formed : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    [loan : i64 state.formed-loan]
    [binder : i64 state.formed-binder]
    [indexed : bool state.formed-indexed]
    [value : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 1)
          formed.block
          depth))]
    (when
      (< formed.block 0)
      (return
        (NormalizeValueResult.Err
          (OwnershipNormalizeFailure.Structural
            "ownership normalization: diverging place formation"))))
    (when (= value.type 13) (return (NormalizeValueResult.Ok value)))
    (unless
      (and (= value.type formed.type) (= node.type 0))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    ;; A store into an unnamed part of an owned place (an element, or box
    ;; contents) writes the whole place: it must be initialized (no element
    ;; ever moves out), every loan of it conflicts, and the value moves in.
    ;; Behind a reference the write goes through the loan as below.
    ;; Overwriting an initialized cleanup owner would lose its cleanup: the
    ;; owned destination must be empty (moved out) first. An element is
    ;; reached only as its whole (initialized) array, and a referent is always
    ;; initialized, so an element store or a store through a reference of a
    ;; cleanup owner is always rejected.
    (when
      (normalize-cleanup-type? (& state) value.type)
      (try
        (normalize-overwrite-check!
          state
          value.block
          formed.place
          (& node.source))))
    (when
      (and indexed (< loan 0))
      (begin
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Read
              (normalize-place-id (& state) formed.place))
            (& node.source)))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Assign
              (normalize-place-id (& state) formed.place))
            (& node.source)))
        ;; The stored value's loans are now held by the whole place.
        (try (normalize-note-flow! state value.place formed.place))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Consume
              (normalize-place-id (& state) value.place))
            (& node.source)))
        (return (normalize-value! state value.block 0 (& node.source)))))
    (if (< loan 0)
      (begin
        ;; A Copy destination is always initialized; a move-only one is
        ;; reinitialized by the store. A store into part of a root uses the
        ;; root, whose other parts stay (Rust's liveness counts it as a use of
        ;; the local); overwriting a whole root reads nothing.
        (when
          (normalize-copy-type? (& state) formed.type)
          (if (<
            (own.ownership-parent
              (& (array-ref state.body.places formed.place)))
            0)
            (try
              (normalize-emit-init-check!
                state
                value.block
                formed.place
                (& node.source)))
            (try
              (normalize-emit!
                state
                value.block
                (own.OwnershipOperation.Read
                  (normalize-place-id (& state) formed.place))
                (& node.source)))))
        (try
          (normalize-transfer!
            state
            value.block
            value.place
            formed.place
            (& node.source))))
      (begin
        ;; Typing checks only the innermost reference: a `&mut` reached
        ;; through a `&` writes through a shared loan.
        (try
          (normalize-exclusive-ok (& state) loan formed.place (& node.source)))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Read (normalize-place-id (& state) binder))
            (& node.source)))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.AccessThrough
              (own.OwnershipLoanId
                (typed.typed-body-copy (& state.body.id))
                loan)
              (normalize-place-id (& state) formed.place)
              own.OwnershipAccess.Write)
            (& node.source)))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Consume
              (normalize-place-id (& state) value.place))
            (& node.source)))
        ;; The referent now holds the value's loans: they stay live while it
        ;; is used, and a parameter's referent is used at every return
        ;; (`normalize-note-exit-referent-uses!`).
        (try (normalize-note-flow! state value.place formed.place))))
    (normalize-value! state value.block 0 (& node.source))))

;; `(replace! place replacement)` (SPEC 5.10.1): the formed place is reserved
;; by a shared loan while the replacement runs, so the replacement may read it
;; but not move, write or mutably borrow it; then the old value moves out to
;; the result and the replacement moves in. An element of an owned array is a
;; write of the whole array; behind a reference the write goes through its
;; loan (a shared one rejects it), and the old value is fresh.
;; Behind an opaque referent (a reference reached through another reference)
;; the referent is reserved and activated directly, as a two-phase borrow of
;; it is (`normalize-reserve-place!`), so the replacement may read it through
;; the same reference; the write then issues the referent's own loan, which is
;; exclusive only when every reference on the path is mutable
;; (`normalize-opaque-referent-of!`): a `&mut` behind a `&` is not writable.
(define (normalize-replace-place!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [formed : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    [loan : i64 state.formed-loan]
    [binder : i64 state.formed-binder]
    [indexed : bool state.formed-indexed]
    [_diverging : unit
      (when
        (< formed.block 0)
        (return
          (NormalizeValueResult.Err
            (OwnershipNormalizeFailure.Structural
              "ownership normalization: diverging place formation"))))]
    [reserve-parent : i64
      (if (normalize-deferred-loan? (& state) loan)
        -1
        loan)]
    [_global : unit
      (when
        (and
          (normalize-global-local?
            (& state)
            (array-ref state.body.places formed.place).local.index)
          (not (normalize-copy-type? (& state) formed.type)))
        (return
          (NormalizeValueResult.Err
            (try (normalize-global-move-out state formed.place (& node.source))))))]
    [reservation : i64 state.loan-count]
    [reservation-source : own.OwnershipSource
      (try (normalize-source-copy! state (& node.source)))]
    [activation-source : own.OwnershipSource
      (try (normalize-source-copy! state (& node.source)))]
    [_reserved : unit
      (begin
        (try (normalize-charge! state 1 1 0))
        (__tl_array-push! state.reservation-loans reservation)
        (normalize-loan-append!
          state
          (own.OwnershipLoan
            (normalize-place-id (& state) formed.place)
            own.OwnershipLoanKind.Shared
            (normalize-loan-origin (& state) reserve-parent)
            reservation-source))
        (try
          (normalize-borrow-emit!
            state
            formed.block
            reservation
            reserve-parent
            binder
            (& node.source))))]
    [value : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 1)
          formed.block
          depth))]
    (when (= value.type 13) (return (NormalizeValueResult.Ok value)))
    (unless
      (and (= value.type formed.type) (= node.type formed.type))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    ;; The reservation is used at the commit: it is live through the
    ;; replacement. The commit activates an exclusive borrow of the place,
    ;; which any other live loan conflicts with.
    (try
      (normalize-emit!
        state
        value.block
        (own.OwnershipOperation.UseLoan
          (own.OwnershipLoanId
            (typed.typed-body-copy (& state.body.id))
            reservation))
        (& node.source)))
    (let
      [activation : i64 state.loan-count]
      (try (normalize-charge! state 1 1 0))
      (normalize-loan-append!
        state
        (own.OwnershipLoan
          (normalize-place-id (& state) formed.place)
          own.OwnershipLoanKind.Exclusive
          (normalize-loan-origin (& state) reserve-parent)
          activation-source))
      (try
        (normalize-borrow-emit!
          state
          value.block
          activation
          reserve-parent
          binder
          (& node.source))))
    (cond
      [(and indexed (< loan 0))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Read
              (normalize-place-id (& state) formed.place))
            (& node.source)))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Assign
              (normalize-place-id (& state) formed.place))
            (& node.source)))
        ;; The new value's loans are held by the whole place, and the old
        ;; value taken out may carry any loan the place held.
        (try (normalize-note-flow! state value.place formed.place))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Consume
              (normalize-place-id (& state) value.place))
            (& node.source)))
        (let
          [old : NormalizeValue
            (try (normalize-value! state value.block node.type (& node.source)))]
          (try (normalize-note-flow! state formed.place old.place))
          (NormalizeValueResult.Ok old))]
      [(< loan 0)
        (let
          [result : i64
            (try (normalize-local! state node.type false (& node.source)))]
          (try
            (normalize-transfer!
              state
              value.block
              formed.place
              result
              (& node.source)))
          (try
            (normalize-transfer!
              state
              value.block
              value.place
              formed.place
              (& node.source)))
          (NormalizeValueResult.Ok
            (NormalizeValue node.type result value.block)))]
      [else
        (try
          (normalize-exclusive-ok (& state) loan formed.place (& node.source)))
        (when
          (>= binder 0)
          (try
            (normalize-emit!
              state
              value.block
              (own.OwnershipOperation.Read
                (normalize-place-id (& state) binder))
              (& node.source))))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.AccessThrough
              (own.OwnershipLoanId
                (typed.typed-body-copy (& state.body.id))
                loan)
              (normalize-place-id (& state) formed.place)
              own.OwnershipAccess.Write)
            (& node.source)))
        (try
          (normalize-emit!
            state
            value.block
            (own.OwnershipOperation.Consume
              (normalize-place-id (& state) value.place))
            (& node.source)))
        ;; The old value leaves with the referent's loans; the replacement's
        ;; flow into the referent (see `normalize-assign-place!`).
        (let
          [old : NormalizeValue
            (try (normalize-value! state value.block node.type (& node.source)))]
          (try (normalize-note-flow! state formed.place old.place))
          (try (normalize-note-flow! state value.place formed.place))
          (NormalizeValueResult.Ok old))])))

;; `(& place)` or `(&mut place)` issues a loan on the formed place. The
;; reference is a fresh value whose origin holds exactly that loan; every later
;; use of the reference keeps the loan alive (`MayUseLoan`).
;; A direct loan, or a reborrow of the entry loan `parent` of a reference
;; parameter whose referent holds the borrowed place.
(define (normalize-loan-origin
  [state : (& state NormalizeState)]
  [parent : i64]) : own.OwnershipLoanOrigin
  (if (< parent 0)
    own.OwnershipLoanOrigin.Direct
    (own.OwnershipLoanOrigin.Parent
      (own.OwnershipLoanId (typed.typed-body-copy (& state.body.id)) parent))))

;; Issues `loan`: a reborrow also uses the reference parameter `via`.
;; Whether `loan` is an opaque-referent loan not yet issued.
(define (normalize-deferred-loan?
  [state : (& state NormalizeState)]
  [loan : i64]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (and (>= loan 0) (< index (array-length state.deferred-loans)))
      (when (= (array-ref state.deferred-loans index) loan) (set! found true))
      (set! index (+ index 1)))
    found))

;; Whether an opaque-referent loan was formed but never accessed.
(define (normalize-deferred-pending? [state : (& state NormalizeState)]) : bool
  (let
    [index : i64 0]
    [pending : bool false]
    (while (< index (array-length state.deferred-loans))
      (when (>= (array-ref state.deferred-loans index) 0) (set! pending true))
      (set! index (+ index 1)))
    pending))

;; Issue a deferred opaque-referent loan here, before the access that uses it.
(define (normalize-issue-deferred!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [loan : i64]
  ;; The access decides the loan's kind: a write or mutable reborrow takes
  ;; it exclusively, a read shares it. An access never widens it: a loan
  ;; through a shared path (`normalize-opaque-referent-of!`) stays shared, and
  ;; the core rejects the write through it.
  [access-exclusive? : bool]) : NormalizeUnit
  (let
    [exclusive? : bool
      (and
        access-exclusive?
        (>= loan 0)
        (< loan (array-length state.body.loans))
        (own.ownership-loan-exclusive? (& (array-ref state.body.loans loan))))]
    [index : i64 0]
    [found : i64 -1]
    (while (< index (array-length state.deferred-loans))
      (when (= (array-ref state.deferred-loans index) loan) (set! found index))
      (set! index (+ index 1)))
    (if (or (< loan 0) (< found 0))
      (NormalizeUnit.Ok unit)
      (let
        [source : own.OwnershipSource
          (try (normalize-loan-source-copy! state loan))]
        (set! (array-ref state.deferred-loans found) -1)
        (set!
          (array-ref state.body.loans loan)
          (own.OwnershipLoan
            (normalize-place-id
              (& state)
              (array-ref state.body.loans loan).place.index)
            (if exclusive?
              own.OwnershipLoanKind.Exclusive
              own.OwnershipLoanKind.Shared)
            own.OwnershipLoanOrigin.Direct
            (own.ownership-source-copy (& source))))
        (normalize-emit!
          state
          block
          (own.OwnershipOperation.Borrow
            (own.OwnershipLoanId (typed.typed-body-copy (& state.body.id)) loan))
          (& source))))))

(define (normalize-borrow-emit!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [loan : i64]
  [parent : i64]
  [via : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (if (begin
    (try
      (normalize-issue-deferred!
        state
        block
        parent
        (own.ownership-loan-exclusive? (& (array-ref state.body.loans loan)))))
    (< parent 0))
    (normalize-emit!
      state
      block
      (own.OwnershipOperation.Borrow
        (own.OwnershipLoanId (typed.typed-body-copy (& state.body.id)) loan))
      source)
    (begin
      (try
        (normalize-emit!
          state
          block
          (own.OwnershipOperation.Read (normalize-place-id (& state) via))
          source))
      (normalize-emit!
        state
        block
        (own.OwnershipOperation.Reborrow
          (own.OwnershipLoanId (typed.typed-body-copy (& state.body.id)) loan))
        source))))

;; A mutable borrow of a place behind a shared reference parameter would
;; grant exclusive authority the parameter does not have (Rust E0596). Access
;; kind 5 names it; the parameter's declaration is the labelled origin.
(define (normalize-exclusive-ok
  [state : (& state NormalizeState)]
  [parent : i64]
  [place : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (if (or
    (< parent 0)
    (own.ownership-loan-exclusive? (& (array-ref state.body.loans parent))))
    (NormalizeUnit.Ok unit)
    (NormalizeUnit.Err
      (OwnershipNormalizeFailure.Borrowed
        (own.OwnershipFailure
          own.OwnershipFailureKind.Loan
          -1
          -1
          place
          -1
          parent
          (own.ownership-source-copy source)
          "mutable borrow through a shared reference")
        (OwnershipBorrowDiagnostic
          (normalize-binder-name state (normalize-place-root state place))
          (normalize-place-fields state place)
          5
          (own.ownership-source-copy
            (& (array-ref state.body.loans parent).source))
          -1
          -1)))))

(define (normalize-borrow!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [mutable? : bool]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [borrowed : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    ;; A place behind a reference parameter is reborrowed from its entry loan.
    [parent : i64 state.formed-loan]
    [via : i64 state.formed-binder]
    [element : i64 state.formed-element]
    [kind : i64
      (if (< (array-length state.type-references) (+ node.type 1))
        0
        (array-ref state.type-references node.type))]
    (unless
      (=
        kind
        (if mutable?
          2
          1))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (when
      mutable?
      (try
        (normalize-exclusive-ok (& state) parent borrowed.place (& node.source))))
    (let
      [loan : i64 state.loan-count]
      ;; The loan is attributed to the borrowed place (the formed child).
      [loan-source : own.OwnershipSource
        (try (normalize-node-source-copy! state (- state.node-count 1)))]
      [result : i64
        (try (normalize-local! state node.type false (& node.source)))]
      (try (normalize-charge! state 1 1 0))
      (normalize-loan-append!
        state
        (own.OwnershipLoan
          (normalize-place-id (& state) borrowed.place)
          (if mutable?
            own.OwnershipLoanKind.Exclusive
            own.OwnershipLoanKind.Shared)
          (normalize-loan-origin (& state) parent)
          loan-source))
      (normalize-element-site!
        state
        borrowed.block
        borrowed.place
        (& node.source)
        element)
      (try
        (normalize-borrow-emit!
          state
          borrowed.block
          loan
          parent
          via
          (& node.source)))
      (try
        (normalize-emit!
          state
          borrowed.block
          (own.OwnershipOperation.Assign (normalize-place-id (& state) result))
          (& node.source)))
      (try (normalize-note-origin! state result loan))
      ;; A reference to a place holding references keeps those loans too,
      ;; and they stay in that place: they are used through it here.
      (try (normalize-note-contents! state borrowed.place result))
      (try
        (normalize-note-use!
          state
          borrowed.block
          (array-ref state.instruction-counts borrowed.block)
          borrowed.place))
      ;; A borrow through a reference keeps that reference's own loans live
      ;; (Rust's `'r: 'c`): the original owner stays borrowed while the
      ;; reborrow is live, even after the reference's last use.
      (when (>= via 0) (try (normalize-note-outlives! state via result)))
      (NormalizeValueResult.Ok (NormalizeValue node.type result borrowed.block)))))

;; Arguments evaluate left to right into fresh temporaries, so a later
;; argument cannot observe a write to an earlier argument's source. The call
;; then consumes every temporary: a move-only argument is transferred to the
;; callee. A call whose result is Never does not return; no cleanup runs after
;; it, matching the language's no-unwind abort policy. A primitive consumes its
;; value operands the same way; its result is a fresh value.
(define (normalize-operands!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (cond
    [(normalize-builtin-code? node 150)
      (normalize-receiver-tail! state store lease node block depth)]
    [(normalize-builtin-code? node 152)
      (normalize-owned-element! state store lease node block depth)]
    [(normalize-builtin-code? node 154)
      (normalize-literal-select! state store lease node block depth)]
    ;; A control-flow receiver is only a store's first operand.
    [(normalize-builtin-code? node 151)
      (NormalizeValueResult.Err
        (OwnershipNormalizeFailure.Structural
          "ownership normalization: store receiver outside its store"))]
    [else (normalize-call! state store lease node block depth)]))

(define (normalize-builtin-code? [node : (& node NormalizeNode)] [code : i64]) : bool
  (match (& node.operation)
    [(NormalizeOperation.Primitive (typed.TypedPrimitive.Builtin found _))
      (= found code)]
    [_ false]))

;; A tail of a control-flow store receiver (form 150, over the mutable borrow
;; of the place it selects, SPEC 5.10): the place is formed here and recorded
;; for its store, which borrows it after the stored value
;; (`normalize-receiver-store!`). The tail's value is an opaque placeholder
;; of the place's type that only the receiver's join reads.
(define (normalize-receiver-tail!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (unless
    (and (> state.receiver-depth 0) (= (array-length node.children) 1))
    (return
      (NormalizeValueResult.Err
        (OwnershipNormalizeFailure.Structural
          "ownership normalization: receiver tail outside a store"))))
  (let
    [receiver : NormalizeDeferredReceiver
      (try
        (normalize-form-store-receiver!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    [formed : i64 receiver.borrowed.block]
    [place : i64 receiver.borrowed.place]
    [retained : NormalizeNode (normalize-borrow-node-copy (& receiver.node))]
    (try (normalize-retain-node! state retained place))
    (__tl_array-push! state.receiver-targets receiver)
    (if (< formed 0)
      (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))
      (normalize-value! state formed node.type (& node.source)))))

;; An element moved out of a `for` loop's private array (form 152): the
;; macro's index visits each element once and no other code names the array,
;; so the array place (child 0) is only read, and the element is a fresh value
;; the item binding owns. An element of an array of references (or of values
;; holding them) holds the array's loans.
(define (normalize-owned-element!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (unless
    (= (array-length node.children) 1)
    (return (NormalizeValueResult.Err (normalize-type-error))))
  (let
    [formed : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    (try
      (normalize-emit!
        state
        formed.block
        (own.OwnershipOperation.Read
          (normalize-place-id (& state) formed.place))
        (& node.source)))
    (let
      [element : NormalizeValue
        (try (normalize-value! state formed.block node.type (& node.source)))]
      (try (normalize-note-flow! state formed.place element.place))
      (NormalizeValueResult.Ok element))))

;; A literal index into an array literal (form 154: the elements, then the
;; literal index): every element is evaluated in order, the selected one moves
;; into the result and the others are dropped, so the result holds only the
;; selected element's loans.
(define (normalize-literal-select!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [count : i64 (array-length node.children)]
    [selected : i64
      (if (< count 2)
        -1
        (try
          (normalize-literal-index!
            state
            store
            lease
            (normalize-child-id node (- count 1)))))]
    [values : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [active : i64 block]
    [index : i64 0]
    [exited? : bool false]
    (unless
      (and (>= selected 0) (< selected (- count 1)))
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (while (< index count)
      (let
        [value : NormalizeValue
          (try
            (normalize-walk!
              state
              store
              lease
              (normalize-child-id node index)
              active
              depth))]
        ;; A diverging element is an exit: the later ones never run (each is
        ;; walked in a block nothing reaches) and nothing is selected.
        (if (or exited? (= value.type 13))
          (begin
            (set! exited? true)
            (set! active (try (normalize-block! state (& node.source)))))
          (begin
            (__tl_array-push! values value.place)
            (set! active value.block)))
        (set! index (+ index 1))))
    (when exited? (return (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))))
    (let
      [result : i64
        (try (normalize-local! state node.type false (& node.source)))]
      (try
        (normalize-transfer!
          state
          active
          (array-ref values selected)
          result
          (& node.source)))
      (set! index 0)
      (while (< index (- count 1))
        (when
          (!= index selected)
          (try
            (normalize-emit!
              state
              active
              (own.OwnershipOperation.Consume
                (normalize-place-id (& state) (array-ref values index)))
              (& node.source))))
        (set! index (+ index 1)))
      (NormalizeValueResult.Ok (NormalizeValue node.type result active)))))

;; A copy of a receiver tail's borrow node: retained (with the place it
;; forms) while the original waits for its reservation at the store.
(define (normalize-borrow-node-copy [node : (& node NormalizeNode)]) : NormalizeNode
  (let
    [children : (__tl_dyn-array typed.TypedOccurrenceId)
      (__tl_make-array typed.TypedOccurrenceId 0)]
    [index : i64 0]
    (while (< index (array-length node.children))
      (begin
        (__tl_array-push!
          children
          (typed.TypedOccurrenceId
            (typed.typed-handle-copy (& (array-ref node.children index).handle))))
        (set! index (+ index 1))))
    (NormalizeNode
      (typed.typed-handle-copy (& node.handle))
      node.type
      (own.ownership-source-copy (& node.source))
      (match (& node.operation)
        [(NormalizeOperation.Borrow mutable?)
          (NormalizeOperation.Borrow mutable?)]
        [_ NormalizeOperation.Sequence])
      children
      -1
      (__tl_make-array i64 0)
      node.typed)))

;; The store through a control-flow receiver: its tails formed the places in
;; `targets` (in its operand order), and after every other operand ran one of
;; them is borrowed for the store, as a single receiver is. Which tail ran is
;; not tracked, so each target is reserved and activated on its own path out
;; of an opaque choice, and its reference joins the store's receiver
;; temporary (`type`). `cleanup?`: the stored value owns a cleanup, so each
;; target must be empty (`normalize-overwrite-check!`).
(define (normalize-receiver-store!
  [state : (&mut state NormalizeState)]
  [targets : (__tl_dyn-array NormalizeDeferredReceiver)]
  [type : i64]
  [cleanup? : bool]
  [block : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeValueResult
  (let
    [count : i64 (array-length targets)]
    [joined : i64 (try (normalize-local! state type false source))]
    [merge : i64 (try (normalize-block! state source))]
    [current : i64 block]
    [index : i64 0]
    (when
      (< count 1)
      (return (NormalizeValueResult.Err (normalize-type-error))))
    (while (< index count)
      (let
        [arm : i64
          (if (< index (- count 1))
            (let
              [choice : NormalizeValue
                (try (normalize-value! state current 1 source))]
              [taken : i64 (try (normalize-block! state source))]
              [rest : i64 (try (normalize-block! state source))]
              (try
                (normalize-terminate!
                  state
                  current
                  (own.OwnershipTerminator.Branch
                    (normalize-place-id (& state) choice.place)
                    (normalize-block-id (& state) taken)
                    (normalize-block-id (& state) rest))))
              (set! current rest)
              taken)
            current)]
        [target : (& targets NormalizeDeferredReceiver)
          (& (array-ref targets index))]
        [_overwrite : unit
          (when
            cleanup?
            (try
              (normalize-overwrite-check!
                state
                arm
                target.borrowed.place
                source)))]
        [mark : i64 state.reserved-count]
        [reserved : NormalizeValue
          (try
            (normalize-reserve-place!
              state
              (& target.node)
              (NormalizeValue target.borrowed.type target.borrowed.place arm)
              target.parent
              target.via
              false))]
        (try (normalize-activate-reservations! state reserved.block mark))
        (try
          (normalize-transfer!
            state
            reserved.block
            reserved.place
            joined
            source))
        (try
          (normalize-terminate!
            state
            reserved.block
            (own.OwnershipTerminator.Goto (normalize-block-id (& state) merge))))
        (set! index (+ index 1))))
    (NormalizeValueResult.Ok (NormalizeValue type joined merge))))

;; The loans the array operand of an element store took (from `first` to
;; `end`), and the activated loans on the same places.
(define (normalize-mark-store-loans!
  [state : (&mut state NormalizeState)]
  [first : i64]
  [end : i64]
  [element : i64]) : unit
  (let
    [loan : i64 first]
    (while (and (>= end 0) (< loan state.loan-count))
      (when
        (or
          (< loan end)
          (normalize-loan-place-among?
            (& state)
            (array-ref state.body.loans loan).place.index
            first
            end))
        (begin
          (__tl_array-push! state.store-loans loan)
          (__tl_array-push! state.store-elements element)))
      (set! loan (+ loan 1)))
    unit))

;; An element store's literal index (child 1 of form 105, 125 or 126), or -1.
(define (normalize-literal-element!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]) : NormalizeInt
  (if (not
    (and
      (= (array-length node.children) 3)
      (match (& node.operation)
        [(NormalizeOperation.Primitive (typed.TypedPrimitive.Builtin code _))
          (or (= code 105) (= code 125) (= code 126))]
        [_ false])))
    (NormalizeInt.Ok -1)
    (normalize-literal-index! state store lease (normalize-child-id node 1))))

;; A nonnegative integer literal occurrence's value, or -1.
(define (normalize-literal-index!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]) : NormalizeInt
  (let
    [header : NormalizeHeader (try (normalize-header! state store lease id))]
    (match (& header.operation)
      [(NormalizeOperation.Literal (ast.AstLiteral.Int value _))
        (NormalizeInt.Ok
          (if (>= value 0)
            value
            -1))]
      [_ (NormalizeInt.Ok -1)])))

;; Records an access of literal fixed-array element `element` (see
;; `element-blocks`).
(define (normalize-element-site!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [place : i64]
  [source : (& source own.OwnershipSource)]
  [element : i64]) : unit
  (when
    (>= element 0)
    (begin
      (__tl_array-push! state.element-blocks block)
      (__tl_array-push! state.element-places place)
      (__tl_array-push! state.element-lines source.line)
      (__tl_array-push! state.element-columns source.column)
      (__tl_array-push! state.element-values element))))

;; The element an access at (block, place, source) names, or -1.
(define (normalize-element-at
  [state : (& state NormalizeState)]
  [block : i64]
  [place : i64]
  [source : (& source own.OwnershipSource)]) : i64
  (let
    [index : i64 0]
    [element : i64 -1]
    (while (and (< element 0) (< index (array-length state.element-blocks)))
      (when
        (and
          (= (array-ref state.element-blocks index) block)
          (= (array-ref state.element-places index) place)
          (= (array-ref state.element-lines index) source.line)
          (= (array-ref state.element-columns index) source.column))
        (set! element (array-ref state.element-values index)))
      (set! index (+ index 1)))
    element))

;; A field code naming array element `element` in a diagnostic path (see
;; `OwnershipMoveDiagnostic.fields`).
(define (normalize-element-field [element : i64]) : i64
  (- -1000000 element))

;; The literal element a store loan writes, or -1.
(define (normalize-store-element
  [state : (& state NormalizeState)]
  [loan : i64]) : i64
  (let
    [index : i64 0]
    [element : i64 -1]
    (while (< index (array-length state.store-loans))
      (when
        (and
          (= (array-ref state.store-loans index) loan)
          (< index (array-length state.store-elements)))
        (set! element (array-ref state.store-elements index)))
      (set! index (+ index 1)))
    element))

(define (normalize-loan-place-among?
  [state : (& state NormalizeState)]
  [place : i64]
  [first : i64]
  [end : i64]) : bool
  (let
    [loan : i64 first]
    [found : bool false]
    (while (and (not found) (< loan end))
      (when
        (= (array-ref state.body.loans loan).place.index place)
        (set! found true))
      (set! loan (+ loan 1)))
    found))

(define (normalize-store-loan? [state : (& state NormalizeState)] [loan : i64]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (< index (array-length state.store-loans))
      (when (= (array-ref state.store-loans index) loan) (set! found true))
      (set! index (+ index 1)))
    found))

;; A store receiver formed but not yet reserved: the mutable-borrow node, its
;; formed place, and the loan and reference binder it was reached through.
(defstruct NormalizeDeferredReceiver
  (node NormalizeNode)
  (borrowed NormalizeValue)
  (parent i64)
  (via i64))

(defenum NormalizeMaybeDeferred
  (Some NormalizeDeferredReceiver)
  (No))

;; A control-flow store receiver's formed targets and reference type.
(defenum NormalizeMaybeSelection
  (Some (__tl_dyn-array NormalizeDeferredReceiver) i64)
  (No))

(defenum NormalizeDeferredResult
  (Ok NormalizeDeferredReceiver)
  (Err OwnershipNormalizeFailure))

(defenum NormalizeBool
  (Ok bool)
  (Err OwnershipNormalizeFailure))

;; Whether occurrence `id` is a control-flow store receiver (form 151).
(define (normalize-receiver-occurrence?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]) : NormalizeBool
  (match (typed.typed-occurrence-get! store lease id)
    [(typed.TypedNodeResult.Ok view)
      (NormalizeBool.Ok
        (match (& view.operation)
          [(typed.TypedOperation.Primitive
              (typed.TypedPrimitive.Builtin code _))
            (= code 151)]
          [_ false]))]
    [(typed.TypedNodeResult.Err error)
      (NormalizeBool.Err (OwnershipNormalizeFailure.Typed error))]))

(define (normalize-mutable-borrow-occurrence?
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]) : NormalizeBool
  (match (typed.typed-occurrence-get! store lease id)
    [(typed.TypedNodeResult.Ok view)
      (NormalizeBool.Ok
        (match (& view.operation)
          [(typed.TypedOperation.Borrow true) true]
          [_ false]))]
    [(typed.TypedNodeResult.Err error)
      (NormalizeBool.Err (OwnershipNormalizeFailure.Typed error))]))

;; Form the place a store's mutable-borrow receiver names, as
;; `normalize-reserve-emit!` does, leaving its reservation to the store.
(define (normalize-form-store-receiver!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [block : i64]
  [depth : i64]) : NormalizeDeferredResult
  (try (normalize-charge! state 1 1 0))
  (let
    [node : NormalizeNode (try (normalize-node! state store lease id))]
    [active : i64
      (if (< block 0)
        (try (normalize-block! state (& node.source)))
        block)]
    [borrowed : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id (& node) 0)
          active
          depth))]
    (unless
      (= (array-length node.children) 1)
      (return (NormalizeDeferredResult.Err (normalize-type-error))))
    (NormalizeDeferredResult.Ok
      (NormalizeDeferredReceiver
        node
        borrowed
        state.formed-loan
        state.formed-binder))))

(define (normalize-call!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [active : i64 block]
    [operands : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    ;; Per operand, the reservation its evaluation pushed (a two-phase
    ;; mutable argument), or -1.
    [reservations : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [index : i64 0]
    [mark : i64 state.reserved-count]
    ;; A store's written operand: an array element (forms 105 and 126, `set!` of
    ;; `array-ref`; form 125 through a slice reference) or box contents (form
    ;; 111, `set!` of `deref`).
    [store? : bool
      (match (& node.operation)
        [(NormalizeOperation.Primitive (typed.TypedPrimitive.Builtin code _))
          (or (= code 105) (= code 111) (= code 125) (= code 126))]
        [_ false])]
    [first-loan : i64 state.loan-count]
    [store-end : i64 -1]
    ;; A store's receiver place is formed in order (its index operands run
    ;; first) but reserved only at the store, after the stored value (SPEC
    ;; 5.10: the destination is resolved again after the right-hand side, which
    ;; may grow or reassign its container but not leave it moved).
    [deferred : NormalizeMaybeDeferred NormalizeMaybeDeferred.No]
    ;; A receiver selecting its place through control flow (form 151) forms a
    ;; place in each tail; one of them is borrowed at the store the same way.
    [selection : NormalizeMaybeSelection NormalizeMaybeSelection.No]
    ;; An operand diverged: the call is never made.
    [exited? : bool false]
    (while (< index (array-length node.children))
      (let
        [before : i64 state.reserved-count]
        [value : NormalizeValue
          (cond
            [(and
                store?
                (= index 0)
                (try
                  (normalize-receiver-occurrence?
                    store
                    lease
                    (normalize-child-id node 0))))
              (let
                [select : NormalizeNode
                  (try
                    (normalize-node!
                      state
                      store
                      lease
                      (normalize-child-id node 0)))]
                [type : i64 select.type]
                [saved : (__tl_dyn-array NormalizeDeferredReceiver)
                  (replace!
                    state.receiver-targets
                    (__tl_make-array NormalizeDeferredReceiver 0))]
                [_open : unit
                  (set! state.receiver-depth (+ state.receiver-depth 1))]
                [selected : NormalizeValue
                  (try
                    (normalize-walk!
                      state
                      store
                      lease
                      (normalize-child-id (& select) 0)
                      active
                      depth))]
                [_close : unit
                  (set! state.receiver-depth (- state.receiver-depth 1))]
                [targets : (__tl_dyn-array NormalizeDeferredReceiver)
                  (replace! state.receiver-targets saved)]
                (unless
                  (= (array-length select.children) 1)
                  (return (NormalizeValueResult.Err (normalize-type-error))))
                (try (normalize-retain-node! state select selected.place))
                (set! selection (NormalizeMaybeSelection.Some targets type))
                (NormalizeValue
                  (if (= selected.type 13)
                    13
                    type)
                  -1
                  selected.block))]
            [(and
                store?
                (= index 0)
                (try
                  (normalize-mutable-borrow-occurrence?
                    store
                    lease
                    (normalize-child-id node 0))))
              (let
                [receiver : NormalizeDeferredReceiver
                  (try
                    (normalize-form-store-receiver!
                      state
                      store
                      lease
                      (normalize-child-id node 0)
                      active
                      depth))]
                [formed : NormalizeValue
                  (NormalizeValue
                    receiver.borrowed.type
                    -1
                    receiver.borrowed.block)]
                (set! deferred (NormalizeMaybeDeferred.Some receiver))
                formed)]
            [else
              (set!
                state.shared-receiver
                (and
                  (= index 0)
                  (match (& node.operation)
                    [(NormalizeOperation.Primitive
                        (typed.TypedPrimitive.Builtin code _))
                      (normalize-builtin-reads-receiver? code)]
                    [_ false])))
              (try
                (normalize-argument-in-context!
                  state
                  store
                  lease
                  (normalize-child-id node index)
                  active
                  depth
                  ;; Calls and builtin forms take two-phase mutable operands;
                  ;; a tuple literal (form 129) and a closure's captures
                  ;; (form 135) move their values in.
                  (match (& node.operation)
                    [(NormalizeOperation.Call _ _ _ _ _ _) true]
                    [(NormalizeOperation.Primitive
                        (typed.TypedPrimitive.Builtin code _))
                      (not (normalize-builtin-moves-operands? code))]
                    [_ false])
                  ;; A constructor's arguments are stored (3); a call's are passed (2).
                  (match (& node.operation)
                    [(NormalizeOperation.Call key _ discharge? _ _ _)
                      (if (and discharge? (< key 0))
                        3
                        2)]
                    [_ 0])))])]
        (if (or exited? (= value.type 13))
          ;; A diverging operand is an exit: the operands after it never run,
          ;; each walked in a block nothing reaches (as a binary's right
          ;; operand after a diverging left one), and the call is never made.
          (begin
            (set! exited? true)
            (set! active (try (normalize-block! state (& node.source)))))
          (begin
            (try (normalize-charge! state 1 1 0))
            (__tl_array-push! operands value.place)
            (__tl_array-push!
              reservations
              (if (= state.reserved-count (+ before 1))
                before
                -1))
            (when (= index 0) (set! store-end state.loan-count))
            (set! active value.block)))
        (set! index (+ index 1))))
    ;; Reservations the evaluated operands made are never activated, and a
    ;; store's receiver formed before the exit is never reserved.
    (when
      exited?
      (set! state.reserved-count mark)
      (match deferred
        [(NormalizeMaybeDeferred.Some receiver)
          (try (normalize-retain-node! state receiver.node -1))]
        [(NormalizeMaybeDeferred.No) unit])
      (return (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))))
    (match selection
      [(NormalizeMaybeSelection.Some targets type)
        (let
          [cleanup? : bool
            (and
              (> (array-length operands) 1)
              (normalize-cleanup-type?
                (& state)
                (array-ref
                  state.body.places
                  (array-ref operands (- (array-length operands) 1))).type.index))]
          [_first : unit (set! first-loan state.loan-count)]
          [joined : NormalizeValue
            (try
              (normalize-receiver-store!
                state
                targets
                type
                cleanup?
                active
                (& node.source)))]
          (set! (array-ref operands 0) joined.place)
          (set! store-end state.loan-count)
          (set! active joined.block))]
      [(NormalizeMaybeSelection.No) unit])
    (match deferred
      [(NormalizeMaybeDeferred.Some receiver)
        (let
          ;; Storing a cleanup owner into an element would lose the cleanup of
          ;; the element it overwrites: the element is reached only as its
          ;; whole array, which must not hold it (as `normalize-assign-place!`).
          [_overwrite : unit
            (when
              (and
                (> (array-length operands) 1)
                (normalize-cleanup-type?
                  (& state)
                  (array-ref
                    state.body.places
                    (array-ref operands (- (array-length operands) 1))).type.index))
              (try
                (normalize-overwrite-check!
                  state
                  active
                  receiver.borrowed.place
                  (& node.source))))]
          [_first : unit (set! first-loan state.loan-count)]
          [reserved : NormalizeValue
            (try
              (normalize-reserve-place!
                state
                (& receiver.node)
                (NormalizeValue
                  receiver.borrowed.type
                  receiver.borrowed.place
                  active)
                receiver.parent
                receiver.via
                false))]
          (try (normalize-retain-node! state receiver.node reserved.place))
          (set! (array-ref operands 0) reserved.place)
          (set! store-end state.loan-count)
          (set! active reserved.block))]
      [(NormalizeMaybeDeferred.No) unit])
    (try (normalize-activate-reservations! state active mark))
    ;; A conflict at a store's or a push's receiver borrow reports as an
    ;; assignment to the written place.
    (when
      (or
        store?
        (match (& node.operation)
          [(NormalizeOperation.Primitive (typed.TypedPrimitive.Builtin code _))
            (= code 104)]
          [_ false]))
      (normalize-mark-store-loans!
        state
        first-loan
        store-end
        (try (normalize-literal-element! state store lease node))))
    ;; A stored value (the last operand of a store, or a push, form 104)
    ;; goes into the place the first operand borrows, which now holds the
    ;; value's loans (an array of references). A parameter's referent keeps
    ;; them live until the body returns (`normalize-note-exit-referent-uses!`).
    (when
      (and
        (or
          store?
          (match (& node.operation)
            [(NormalizeOperation.Primitive
                (typed.TypedPrimitive.Builtin code _))
              (= code 104)]
            [_ false]))
        (>= store-end 0)
        (> (array-length operands) 1))
      (let
        [stored : i64 (array-ref operands (- (array-length operands) 1))]
        [loan : i64 first-loan]
        (when
          (!= (normalize-reference-kind (& state) stored) 0)
          (while (< loan store-end)
            (let
              [target : i64 (array-ref state.body.loans loan).place.index]
              (try (normalize-note-flow! state stored target))
              (set! loan (+ loan 1)))))))
    ;; A call that may assign a module value writes it here, after its
    ;; operands (#7904); a safe spawn (form 136) is keyed by its occurrence.
    (match (& node.operation)
      [(NormalizeOperation.Call _ _ _ _ _ record)
        (try (normalize-global-writes! state active record (& node.source)))]
      [_
        (when
          (normalize-builtin-code? node 136)
          (try
            (normalize-global-writes!
              state
              active
              (- -2 node.handle.index)
              (& node.source))))])
    ;; A slice element (form 125) is always initialized: storing a cleanup
    ;; owner over it would lose its cleanup. The activated slice reference is
    ;; what is checked, so such a store is always rejected.
    (when
      (and
        (normalize-builtin-code? node 125)
        (> (array-length operands) 2)
        (normalize-cleanup-type?
          (& state)
          (array-ref
            state.body.places
            (array-ref operands (- (array-length operands) 1))).type.index))
      (try
        (normalize-overwrite-check!
          state
          active
          (array-ref operands 0)
          (& node.source))))
    (set! index 0)
    (while (< index (array-length operands))
      (begin
        ;; An owner's value passed on is discharged only by its declared
        ;; cleanup function or a cleanup-owning aggregate's constructor.
        (try
          (normalize-obligation-consume!
            state
            (array-ref operands index)
            (match (& node.operation)
              [(NormalizeOperation.Call _ _ discharge? _ _ _) discharge?]
              [_ false])
            (& node.source)))
        (try
          (normalize-emit!
            state
            active
            (own.OwnershipOperation.Consume
              (normalize-place-id (& state) (array-ref operands index)))
            (& node.source)))
        (set! index (+ index 1))))
    (if (= node.type 13)
      (begin
        (try (normalize-terminate! state active own.OwnershipTerminator.Abort))
        (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1)))
      (let
        [result : NormalizeValue
          (try (normalize-value! state active node.type (& node.source)))]
        ;; A call relates its operands and result through its callee's
        ;; signature, instantiated afresh for this call
        ;; (`normalize-region-edges`). An operation without one (a
        ;; primitive) may put any operand's loans in its result.
        (let
          [signature : i64
            (match (& node.operation)
              [(NormalizeOperation.Call _ _ _ _ signature _) signature]
              [_ -1])]
          (if (>= signature 0)
            (normalize-note-call!
              state
              signature
              (& operands)
              result.place
              (match (& node.operation)
                [(NormalizeOperation.Call _ _ _ indirect? _ _) indirect?]
                [_ false]))
            (begin
              (set! index 0)
              (while (< index (array-length operands))
                (try
                  (normalize-note-flow!
                    state
                    (array-ref operands index)
                    result.place))
                (set! index (+ index 1))))))
        (match (& node.operation)
          [(NormalizeOperation.Call _ _ _ _ _ _)
            (try
              (normalize-temporary-disposals!
                state
                result.block
                (& operands)
                (& node.source)))]
          [_ unit])
        (NormalizeValueResult.Ok result)))))

;; The place of every global binder the write table names, made before the
;; walk: a module value is initialized at entry wherever it is first named.
(define (normalize-global-places!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]) : NormalizeUnit
  (let
    [records : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [index : i64 0]
    (normalize-append-unique! (&mut records) (& state.global-writes.binders))
    (normalize-append-unique!
      (&mut records)
      (& state.global-writes.cleanup-binders))
    (normalize-append-unique!
      (&mut records)
      (& state.global-writes.owner-binders))
    (try (normalize-charge! state 0 (array-length records) 0))
    (while (< index (array-length records))
      (let
        [id : typed.TypedBinderId
          (match (typed.typed-binder-at! store lease (array-ref records index))
            [(typed.TypedBinderResult.Ok id) id]
            [(typed.TypedBinderResult.Err error)
              (return
                (NormalizeUnit.Err (OwnershipNormalizeFailure.Typed error)))])]
        [place : i64 (try (normalize-binder! state store lease id))]
        (__tl_array-push! state.global-binders (array-ref records index))
        (__tl_array-push! state.global-places place))
      (set! index (+ index 1)))
    (NormalizeUnit.Ok unit)))

(define (normalize-global-place
  [state : (& state NormalizeState)]
  [binder : i64]) : i64
  (let
    [index : i64 0]
    (while (< index (array-length state.global-binders))
      (when
        (= (array-ref state.global-binders index) binder)
        (return (array-ref state.global-places index)))
      (set! index (+ index 1)))
    -1))

;; The first index of sorted `calls` at or after `record`.
(define (normalize-entries-lower-bound
  [calls : (& calls (__tl_dyn-array i64))]
  [record : i64]) : i64
  (let
    [low : i64 0]
    [high : i64 (array-length calls)]
    (while (< low high)
      (let
        [middle : i64 (/ (+ low high) 2)]
        (if (< (array-ref calls middle) record)
          (set! low (+ middle 1))
          (set! high middle))))
    low))

;; A `with` owner's cleanup runs at this exit of its scope (a move-aware
;; owner's may): it assigns each module value it may assign (#7904).
(define (normalize-owner-cleanup-writes!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [owner : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [count : i64 (array-length state.global-writes.owners)]
    [record : i64 -1]
    [index : i64 0]
    (when (= count 0) (return (NormalizeUnit.Ok unit)))
    (try (normalize-charge! state 0 (+ count (array-length state.binders)) 0))
    (while (< index (array-length state.binders))
      (when
        (= (array-ref state.binders index).place owner)
        (set! record (array-ref state.binders index).handle.index))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index count)
      (when
        (and
          (>= record 0)
          (= (array-ref state.global-writes.owners index) record))
        (try
          (normalize-global-write!
            state
            block
            (array-ref state.global-writes.owner-binders index)
            (array-ref state.global-writes.owner-callees index)
            (array-ref state.global-writes.owner-globals index)
            (array-ref state.global-writes.owner-pending? index)
            source)))
      (set! index (+ index 1)))
    (NormalizeUnit.Ok unit)))

;; Typed call record `record` assigns each module value it may assign
;; (`OwnershipNormalizeGlobalWrites`, sorted by call record), as the callee
;; would: any loan of that global still live at the call conflicts, whatever
;; reference holds it (#7904).
(define (normalize-global-writes!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [record : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [count : i64 (array-length state.global-writes.calls)]
    [index : i64
      (normalize-entries-lower-bound (& state.global-writes.calls) record)]
    (try (normalize-charge! state 0 64 0))
    (while (and
      (!= record -1)
      (< index count)
      (= (array-ref state.global-writes.calls index) record))
      (try
        (normalize-global-write!
          state
          block
          (array-ref state.global-writes.binders index)
          (array-ref state.global-writes.callees index)
          (array-ref state.global-writes.globals index)
          (array-ref state.global-writes.pending? index)
          source))
      (set! index (+ index 1)))
    (NormalizeUnit.Ok unit)))

;; A temporary of a type with a declared cleanup, borrowed for a call, is
;; disposed of when the call returns: its cleanup assigns each module value
;; it may assign there (#7904), after the call's own loans ended but while a
;; reference the call returned, or an enclosing call's operand, may still
;; hold a loan of that global.
(define (normalize-temporary-disposals!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [operands : (& operands (__tl_dyn-array i64))]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [count : i64 (array-length state.global-writes.cleanup-keys)]
    [index : i64 0]
    (when (= count 0) (return (NormalizeUnit.Ok unit)))
    (try
      (normalize-charge!
        state
        0
        (* (array-length operands) (+ count state.origin-count))
        0))
    (while (< index (array-length operands))
      (let
        [root : i64 (normalize-place-root (& state) (array-ref operands index))]
        [at : i64 0]
        (while (< at state.origin-count)
          (when
            (= (array-ref state.origin-places at) root)
            (let
              [held : i64
                (normalize-place-root
                  (& state)
                  (array-ref state.body.loans (array-ref state.origin-loans at)).place.index)]
              [type : i64 (array-ref state.body.places held).type.index]
              [key : i64
                (if (and (>= type 0) (< type (array-length state.type-keys)))
                  (array-ref state.type-keys type)
                  -1)]
              [entry : i64 0]
              ;; A temporary: a value with no binder name of its own, and not
              ;; the synthetic referent of a reference (a call's result, say),
              ;; which nothing disposes of.
              (when
                (and
                  (>= key 0)
                  (< (normalize-binder-name (& state) held) 0)
                  (= (normalize-region-root (& state) held) held))
                (while (< entry count)
                  (when
                    (= (array-ref state.global-writes.cleanup-keys entry) key)
                    (try
                      (normalize-global-write!
                        state
                        block
                        (array-ref state.global-writes.cleanup-binders entry)
                        (array-ref state.global-writes.cleanup-callees entry)
                        (array-ref state.global-writes.cleanup-globals entry)
                        (array-ref state.global-writes.cleanup-pending? entry)
                        source)))
                  (set! entry (+ entry 1))))))
          (set! at (+ at 1))))
      (set! index (+ index 1)))
    (NormalizeUnit.Ok unit)))

;; Assign the module value of typed binder record `binder` at `block`, as
;; effect-graph node `callee` may (global node `global`); kept, with the
;; whole source of the call, for the diagnostic. A `pending?` effect is
;; probed instead: a fresh scalar is read there, and once the body is
;; certified the point is checked for a live loan of the global
;; (`normalize-deferred-effects`).
(define (normalize-global-write!
  [state : (&mut state NormalizeState)]
  [block : i64]
  [binder : i64]
  [callee : i64]
  [global : i64]
  [pending? : bool]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [place : i64 (normalize-global-place (& state) binder)]
    [copy : own.OwnershipSource (try (normalize-source-copy! state source))]
    (when
      (< place 0)
      (return
        (NormalizeUnit.Err
          (OwnershipNormalizeFailure.Structural
            "ownership normalization: unresolved global binder"))))
    (if pending?
      (let
        [marker : i64 (try (normalize-local! state 0 true source))]
        (try
          (normalize-emit!
            state
            block
            (own.OwnershipOperation.Read (normalize-place-id (& state) marker))
            source))
        (__tl_array-push! state.probe-places marker)
        (__tl_array-push! state.probe-targets place)
        (__tl_array-push! state.probe-callees callee)
        (__tl_array-push! state.probe-globals global)
        (__tl_array-push! state.probe-sources copy))
      (begin
        (try
          (normalize-emit!
            state
            block
            (own.OwnershipOperation.Assign (normalize-place-id (& state) place))
            source))
        (__tl_array-push! state.effect-places place)
        (__tl_array-push! state.effect-sources copy)
        (__tl_array-push! state.effect-callees callee)
        (__tl_array-push! state.effect-globals global)))
    (NormalizeUnit.Ok unit)))

;; The records of the global binders some loan borrows (a module value or a
;; part of one): only such a global can conflict with a call's effect on it.
(define (normalize-borrowed-globals [state : (& state NormalizeState)]) : (__tl_dyn-array
    i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [index : i64 0]
    (while (< index (array-length state.binders))
      (let
        [place : i64 (array-ref state.binders index).place]
        [loan : i64 0]
        [found : bool false]
        (when
          (normalize-global-local?
            state
            (array-ref state.body.places place).local.index)
          (while (and (not found) (< loan (array-length state.body.loans)))
            (when
              (=
                (normalize-place-root
                  state
                  (array-ref state.body.loans loan).place.index)
                place)
              (set! found true))
            (set! loan (+ loan 1)))
          (when
            found
            (__tl_array-push! out (array-ref state.binders index).handle.index))))
      (set! index (+ index 1)))
    out))

;; The work `normalize-deferred-effects` does: one pass over the
;; instructions and the edges, and per probe the loans and one backward walk
;; of the blocks and edges.
(define (normalize-deferred-work [state : (& state NormalizeState)]) : i64
  (let
    [instructions : i64 0]
    [edges : i64 0]
    [block : i64 0]
    (while (< block (array-length state.body.blocks))
      (set!
        instructions
        (+
          instructions
          1
          (array-length (array-ref state.body.blocks block).instructions)))
      (set! edges (+ edges (normalize-block-successor-count state block)))
      (set! block (+ block 1)))
    (+
      instructions
      (* 2 edges)
      (array-length state.body.places)
      (*
        (array-length state.probe-places)
        (+
          (array-length state.body.loans)
          (array-length state.body.blocks)
          edges
          1)))))

;; The probes at which a loan of the probed global may be in force, by the
;; certified body: the loan is live there (some later use may read it) and
;; its borrow reaches the probe, so it may have been issued. Those calls
;; conflict if the effect graph later finds that the callee may assign the
;; global; this is the check the core applies to a known effect's write.
(defenum NormalizeDeferredEffectsResult
  (Ok OwnershipNormalizeDeferred)
  (Err OwnershipNormalizeFailure))

(define (normalize-deferred-effects
  [state : (& state NormalizeState)]
  [limits : own.OwnershipLimits]) : NormalizeDeferredEffectsResult
  (let
    [out : OwnershipNormalizeDeferred
      (OwnershipNormalizeDeferred
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array i64 0)
        (__tl_make-array own.OwnershipSource 0)
        (__tl_make-array own.OwnershipSource 0))]
    ;; Without loans no global is borrowed (the liveness table is then empty).
    (when
      (or
        (= (array-length state.probe-places) 0)
        (= (array-length state.body.loans) 0))
      (return (NormalizeDeferredEffectsResult.Ok out)))
    (match (own.ownership-loan-liveness (& state.body) limits)
      [(own.OwnershipLoanLivenessResult.Err _)
        (NormalizeDeferredEffectsResult.Err OwnershipNormalizeFailure.Resource)]
      [(own.OwnershipLoanLivenessResult.Ok liveness)
        (let
          [places : i64 (array-length state.body.places)]
          [loans : i64 (array-length state.body.loans)]
          [blocks : i64 (array-length state.body.blocks)]
          ;; Per place, the probe whose marker it is; per probe, its block and
          ;; point; per loan, the block and instruction of its borrow.
          [probe-of : (__tl_dyn-array i64) (__tl_make-array i64 places)]
          [probe-blocks : (__tl_dyn-array i64)
            (__tl_make-array i64 (array-length state.probe-places))]
          [probe-indices : (__tl_dyn-array i64)
            (__tl_make-array i64 (array-length state.probe-places))]
          [loan-blocks : (__tl_dyn-array i64) (__tl_make-array i64 loans)]
          [loan-indices : (__tl_dyn-array i64) (__tl_make-array i64 loans)]
          ;; Per block, the last probe it has a path of edges to.
          [predecessors : NormalizePredecessors
            (normalize-block-predecessors state)]
          [marks : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
          [work : (__tl_dyn-array i64) (__tl_make-array i64 (+ blocks 1))]
          [index : i64 0]
          [block : i64 0]
          (while (< index places)
            (set! (array-ref probe-of index) -1)
            (set! index (+ index 1)))
          (set! index 0)
          (while (< index blocks)
            (set! (array-ref marks index) -1)
            (set! index (+ index 1)))
          (set! index 0)
          (while (< index (array-length state.probe-places))
            (set!
              (array-ref probe-of (array-ref state.probe-places index))
              index)
            (set! (array-ref probe-blocks index) -1)
            (set! (array-ref probe-indices index) -1)
            (set! index (+ index 1)))
          (set! index 0)
          (while (< index loans)
            (set! (array-ref loan-blocks index) -1)
            (set! (array-ref loan-indices index) -1)
            (set! index (+ index 1)))
          (while (< block blocks)
            (let
              [instructions : (&
                state
                (__tl_dyn-array own.OwnershipInstruction))
                (& (array-ref state.body.blocks block).instructions)]
              [at : i64 0]
              (while (< at (array-length instructions))
                (let
                  [op : (& state own.OwnershipOperation)
                    (& (array-ref instructions at).operation)]
                  [defined : i64 (own.ownership-loan-definition op)]
                  (when
                    (and (>= defined 0) (< defined loans))
                    (set! (array-ref loan-blocks defined) block)
                    (set! (array-ref loan-indices defined) at))
                  (match op
                    [(own.OwnershipOperation.Read place)
                      (when
                        (and
                          (>= place.index 0)
                          (< place.index places)
                          (>= (array-ref probe-of place.index) 0))
                        (set!
                          (array-ref
                            probe-blocks
                            (array-ref probe-of place.index))
                          block)
                        (set!
                          (array-ref
                            probe-indices
                            (array-ref probe-of place.index))
                          at))]
                    [_ unit]))
                (set! at (+ at 1))))
            (set! block (+ block 1)))
          (set! index 0)
          (while (< index (array-length state.probe-places))
            (let
              [probe-block : i64 (array-ref probe-blocks index)]
              [loan : i64 0]
              [found : i64 -1]
              [marked? : bool false]
              (when
                (and
                  (>= probe-block 0)
                  (< probe-block (array-length liveness.offsets)))
                (let
                  [point : i64
                    (+
                      (array-ref liveness.offsets probe-block)
                      (array-ref probe-indices index))]
                  (while (and (< found 0) (< loan loans))
                    (when
                      (and
                        (=
                          (normalize-place-root
                            state
                            (array-ref state.body.loans loan).place.index)
                          (array-ref state.probe-targets index))
                        (own.ownership-loan-live? (& liveness) point loan))
                      ;; The borrow reaches the probe: earlier in its block,
                      ;; or in a block with a path of edges to it.
                      (unless
                        marked?
                        (set! marked? true)
                        (normalize-mark-reaching!
                          (& predecessors)
                          probe-block
                          index
                          (&mut marks)
                          (&mut work)))
                      (let
                        [from : i64 (array-ref loan-blocks loan)]
                        (when
                          (or
                            (and
                              (= from probe-block)
                              (<
                                (array-ref loan-indices loan)
                                (array-ref probe-indices index)))
                            (and (>= from 0) (= (array-ref marks from) index)))
                          (set! found loan))))
                    (set! loan (+ loan 1))))
                (when
                  (>= found 0)
                  (__tl_array-push!
                    out.callees
                    (array-ref state.probe-callees index))
                  (__tl_array-push!
                    out.globals
                    (array-ref state.probe-globals index))
                  (__tl_array-push!
                    out.names
                    (normalize-binder-name
                      state
                      (array-ref state.probe-targets index)))
                  (__tl_array-push!
                    out.calls
                    (own.ownership-source-copy
                      (& (array-ref state.probe-sources index))))
                  (__tl_array-push!
                    out.borrows
                    (own.ownership-source-copy
                      (& (array-ref state.body.loans found).source))))))
            (set! index (+ index 1)))
          (NormalizeDeferredEffectsResult.Ok out))])))

;; Mark with `stamp` every block that has a path of at least one edge to
;; `target`: one backward walk, each block entering `work` at most once.
(define (normalize-mark-reaching!
  [predecessors : (& predecessors NormalizePredecessors)]
  [target : i64]
  [stamp : i64]
  [marks : (&mut marks (__tl_dyn-array i64))]
  [work : (&mut work (__tl_dyn-array i64))]) : unit
  (let
    [head : i64 0]
    [tail : i64 1]
    (set! (array-ref work 0) target)
    (while (< head tail)
      (let
        [block : i64 (array-ref work head)]
        [at : i64 (array-ref predecessors.start block)]
        (set! head (+ head 1))
        (while (< at (array-ref predecessors.start (+ block 1)))
          (let
            [from : i64 (array-ref predecessors.list at)]
            (when
              (!= (array-ref marks from) stamp)
              (set! (array-ref marks from) stamp)
              (set! (array-ref work tail) from)
              (set! tail (+ tail 1))))
          (set! at (+ at 1)))))))

;; The global assignment a call made with exactly `source` to the root of
;; `place` (`normalize-global-write!`), or -1.
(define (normalize-global-effect-at
  [state : (& state NormalizeState)]
  [place : i64]
  [source : (& source own.OwnershipSource)]) : i64
  (let
    [root : i64 (normalize-place-root state place)]
    [index : i64 0]
    (while (< index (array-length state.effect-places))
      (let
        [effect : (& state own.OwnershipSource)
          (& (array-ref state.effect-sources index))]
        (when
          (and
            (= (array-ref state.effect-places index) root)
            (= effect.line source.line)
            (= effect.column source.column)
            (string.eq (& effect.path) (& source.path))
            (string.eq (& effect.expansion) (& source.expansion)))
          (return index)))
      (set! index (+ index 1)))
    -1))

(define (normalize-execute!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [count : i64 (array-length node.children)]
    [valid? : bool
      (match (& node.operation)
        [(NormalizeOperation.Literal _) (= count 0)]
        [(NormalizeOperation.Read _) (= count 0)]
        [(NormalizeOperation.Invalidate _) (= count 0)]
        [(NormalizeOperation.EndBrand _) (= count 0)]
        [(NormalizeOperation.ThreadUsers _) (= count 0)]
        [(NormalizeOperation.RequireReleased _ _) (= count 0)]
        [(NormalizeOperation.RequireUnheld _ _ _) (= count 0)]
        [(NormalizeOperation.Initialize _) (= count 1)]
        [(NormalizeOperation.Assign _) (= count 1)]
        [(NormalizeOperation.Unary _) (= count 1)]
        [(NormalizeOperation.Binary _) (= count 2)]
        [(NormalizeOperation.If) (= count 3)]
        [(NormalizeOperation.While) (= count 2)]
        [(NormalizeOperation.Break) (= count 0)]
        [(NormalizeOperation.Continue) (= count 0)]
        [(NormalizeOperation.Return _) (<= count 1)]
        [(NormalizeOperation.Sequence) true]
        [(NormalizeOperation.Call _ arguments _ _ _ _) (= count arguments)]
        [(NormalizeOperation.Primitive primitive)
          (= count (typed.typed-primitive-arity primitive))]
        [(NormalizeOperation.FormPlace _) true]
        [(NormalizeOperation.TakePlace) (= count 1)]
        [(NormalizeOperation.AssignPlace) (= count 2)]
        [(NormalizeOperation.ReplacePlace) (= count 2)]
        [(NormalizeOperation.Borrow _) (= count 1)]
        [(NormalizeOperation.Match _) (>= count 2)]
        ;; Arms and patterns are walked by their match only.
        [(NormalizeOperation.Arm) false]
        [(NormalizeOperation.Pattern _) false])]
    (unless
      valid?
      (return
        (NormalizeValueResult.Err
          (OwnershipNormalizeFailure.Structural
            "ownership normalization: selected child arity"))))
    (match (& node.operation)
      [(NormalizeOperation.Literal literal)
        (if (normalize-literal-type? literal node.type)
          (normalize-value! state block node.type (& node.source))
          (NormalizeValueResult.Err (normalize-type-error)))]
      [(NormalizeOperation.Read binder)
        (let
          [source : i64
            (try
              (normalize-binder!
                state
                store
                lease
                (typed.TypedBinderId
                  (typed.typed-handle-copy (& binder.handle)))))]
          [type : i64 (array-ref state.body.places source).type.index]
          (unless
            (= type node.type)
            (return (NormalizeValueResult.Err (normalize-type-error))))
          (let
            [dest : i64
              (try (normalize-local! state type false (& node.source)))]
            (try (normalize-transfer! state block source dest (& node.source)))
            (when
              (and
                (= (normalize-binder-owner (& state) source) 1)
                (not (normalize-copy-type? (& state) type)))
              (try
                (normalize-owner-moved! state block source dest (& node.source))))
            ;; Reading an affine handle whole moves it: the copy leaves
            ;; the binder empty.
            (when
              (and
                (= (normalize-binder-owner (& state) source) 3)
                (normalize-copy-type? (& state) type))
              (try
                (normalize-emit!
                  state
                  block
                  (own.OwnershipOperation.Invalidate
                    (normalize-place-id (& state) source))
                  (& node.source))))
            (NormalizeValueResult.Ok (NormalizeValue type dest block))))]
      [(NormalizeOperation.EndBrand binder)
        (let
          [target : i64
            (try
              (normalize-binder!
                state
                store
                lease
                (typed.TypedBinderId
                  (typed.typed-handle-copy (& binder.handle)))))]
          (try (normalize-end-brand! state block target (& node.source)))
          (normalize-value! state block node.type (& node.source)))]
      [(NormalizeOperation.ThreadUsers binder)
        (let
          [owner : i64
            (try
              (normalize-binder!
                state
                store
                lease
                (typed.TypedBinderId
                  (typed.typed-handle-copy (& binder.handle)))))]
          [marker : i64 (try (normalize-thread-marker! state owner))]
          (try
            (normalize-emit!
              state
              block
              (own.OwnershipOperation.Assign
                (normalize-place-id (& state) marker))
              (& node.source)))
          (normalize-value! state block node.type (& node.source)))]
      ;; Exit 9 (destroy) or 10 (rewind): the owner must be empty here.
      [(NormalizeOperation.RequireUnheld checked binder rewind?)
        (let
          [owner : i64
            (try
              (normalize-binder!
                state
                store
                lease
                (typed.TypedBinderId
                  (typed.typed-handle-copy (& checked.handle)))))]
          [arena : i64
            (try
              (normalize-binder!
                state
                store
                lease
                (typed.TypedBinderId
                  (typed.typed-handle-copy (& binder.handle)))))]
          (try
            (normalize-exit-check!
              state
              block
              owner
              owner
              0
              (if rewind?
                10
                9)
              (own.OwnershipOperation.RequireEmpty
                (normalize-place-id (& state) owner))
              (& node.source)))
          (set!
            (array-ref state.exit-arenas (- (array-length state.exit-arenas) 1))
            arena)
          (normalize-value! state block node.type (& node.source)))]
      [(NormalizeOperation.RequireReleased checked binder)
        (let
          [user : i64
            (try
              (normalize-binder!
                state
                store
                lease
                (typed.TypedBinderId
                  (typed.typed-handle-copy (& checked.handle)))))]
          [owner : i64
            (try
              (normalize-binder!
                state
                store
                lease
                (typed.TypedBinderId
                  (typed.typed-handle-copy (& binder.handle)))))]
          (try
            (normalize-release-check! state block user owner (& node.source)))
          (normalize-value! state block node.type (& node.source)))]
      [(NormalizeOperation.Invalidate binder)
        (let
          [target : i64
            (try
              (normalize-binder!
                state
                store
                lease
                (typed.TypedBinderId
                  (typed.typed-handle-copy (& binder.handle)))))]
          (try
            (normalize-emit!
              state
              block
              (own.OwnershipOperation.Invalidate
                (normalize-place-id (& state) target))
              (& node.source)))
          (normalize-value! state block node.type (& node.source)))]
      [(NormalizeOperation.Initialize binder)
        (normalize-bind-write!
          state
          store
          lease
          node
          (typed.TypedBinderId (typed.typed-handle-copy (& binder.handle)))
          false
          block
          depth)]
      [(NormalizeOperation.Assign binder)
        (normalize-bind-write!
          state
          store
          lease
          node
          (typed.TypedBinderId (typed.typed-handle-copy (& binder.handle)))
          true
          block
          depth)]
      [(NormalizeOperation.Unary op)
        (normalize-unary! state store lease node op block depth)]
      [(NormalizeOperation.Binary op)
        (normalize-binary! state store lease node op block depth)]
      [(NormalizeOperation.If)
        (normalize-if! state store lease node block depth)]
      [(NormalizeOperation.While)
        (normalize-while! state store lease node block depth)]
      [(NormalizeOperation.Break)
        (normalize-loop-control! state node block state.break-target 2)]
      [(NormalizeOperation.Continue)
        (normalize-loop-control! state node block state.continue-target 3)]
      [(NormalizeOperation.Sequence)
        (normalize-sequence! state store lease node block depth)]
      [(NormalizeOperation.Return propagates?)
        (normalize-return! state store lease node block depth propagates?)]
      [(NormalizeOperation.Call _ _ _ _ _ _)
        (normalize-call! state store lease node block depth)]
      [(NormalizeOperation.Primitive _)
        (normalize-operands! state store lease node block depth)]
      [(NormalizeOperation.FormPlace place)
        (normalize-form-place!
          state
          store
          lease
          node
          (typed.TypedPlaceId (typed.typed-handle-copy (& place.handle)))
          block
          depth)]
      [(NormalizeOperation.TakePlace)
        (normalize-take-place! state store lease node block depth)]
      [(NormalizeOperation.AssignPlace)
        (normalize-assign-place! state store lease node block depth)]
      [(NormalizeOperation.ReplacePlace)
        (normalize-replace-place! state store lease node block depth)]
      [(NormalizeOperation.Match borrowed?)
        (normalize-match! state store lease node borrowed? block depth)]
      [(NormalizeOperation.Arm)
        (NormalizeValueResult.Err (normalize-type-error))]
      [(NormalizeOperation.Pattern _)
        (NormalizeValueResult.Err (normalize-type-error))]
      [(NormalizeOperation.Borrow mutable?)
        (normalize-borrow! state store lease node mutable? block depth)])))

;; --- Match ------------------------------------------------------------------
;; One arm's pattern is scanned once in the testing block: every refutable
;; node (a variant or literal test) reads its position, and each binder is
;; recorded with the position it takes (-1 in a borrowed match). The arm
;; branches on an opaque test result; its block then performs the bindings.
(define (normalize-pattern!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [borrowed? : bool]
  [scrutinee : i64]
  [block : i64]
  [depth : i64]) : NormalizeInt
  (unless
    (< depth state.limits.depth)
    (return (NormalizeInt.Err OwnershipNormalizeFailure.Resource)))
  (normalize-pattern-node!
    state
    store
    lease
    (try (normalize-node! state store lease id))
    borrowed?
    scrutinee
    block
    depth))

;; A pattern node already read (`normalize-node!` reads each node once).
(define (normalize-pattern-node!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : NormalizeNode]
  [borrowed? : bool]
  [scrutinee : i64]
  [block : i64]
  [depth : i64]) : NormalizeInt
  (let
    [position : i64 -1]
    [boxed : bool false]
    [refutable : i64 0]
    [index : i64
      (if borrowed?
        0
        1)]
    (unless
      borrowed?
      (let
        [formed : NormalizeValue
          (begin
            (when
              (= (array-length node.children) 0)
              (return
                (NormalizeInt.Err
                  (OwnershipNormalizeFailure.Structural
                    "ownership normalization: pattern without a position"))))
            (try
              (normalize-walk!
                state
                store
                lease
                (normalize-child-id (& node) 0)
                block
                depth)))]
        ;; Owned box contents are reached through the whole box (a
        ;; boxed route): a binding there reads the box for a Copy
        ;; value and consumes it for a move-only one.
        (when
          (or
            (>= state.formed-loan 0)
            (and state.formed-indexed (not state.formed-boxed)))
          (return
            (NormalizeInt.Err
              (OwnershipNormalizeFailure.Unsupported
                "ownership normalization: match on a place behind a reference or at an array element"))))
        (set! boxed state.formed-indexed)
        (set! position formed.place)))
    (match (& node.operation)
      [(NormalizeOperation.Pattern kind)
        (match kind
          [(NormalizePattern.Test)
            (set! refutable 1)
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.Read
                  (normalize-place-id
                    (& state)
                    (if borrowed?
                      scrutinee
                      position)))
                (& node.source)))]
          [(NormalizePattern.Bind binder)
            (try (normalize-charge! state 1 1 0))
            (__tl_array-push!
              state.pattern-binders
              (typed.TypedBinderId (typed.typed-handle-copy (& binder.handle))))
            (__tl_array-push! state.pattern-positions position)
            (__tl_array-push! state.pattern-boxed boxed)
            (__tl_array-push!
              state.pattern-sources
              (if borrowed?
                scrutinee
                -1))]
          ;; The length test reads the reference.
          [(NormalizePattern.Slice)
            (set! refutable 1)
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.Read
                  (normalize-place-id
                    (& state)
                    (if borrowed?
                      scrutinee
                      position)))
                (& node.source)))]
          [(NormalizePattern.Alternatives)
            (return
              (NormalizeInt.Err
                (OwnershipNormalizeFailure.Structural
                  "ownership normalization: binding or-pattern below an arm's top")))]
          [_ unit])]
      [_
        (return
          (NormalizeInt.Err
            (OwnershipNormalizeFailure.Structural
              "ownership normalization: arm pattern is not a pattern")))])
    (let
      ;; A slice pattern's elements are reached through its reference:
      ;; they have no positions and derive from that reference.
      [slice? : bool
        (match (& node.operation)
          [(NormalizeOperation.Pattern (NormalizePattern.Slice)) true]
          [_ false])]
      (while (< index (array-length node.children))
        (when
          (=
            (try
              (normalize-pattern!
                state
                store
                lease
                (normalize-child-id (& node) index)
                (or borrowed? slice?)
                (if (and slice? (not borrowed?))
                  position
                  scrutinee)
                block
                (+ depth 1)))
            1)
          (set! refutable 1))
        (set! index (+ index 1))))
    (try (normalize-retain-node! state node -1))
    (NormalizeInt.Ok refutable)))

(define (normalize-arm? [node : (& node NormalizeNode)]) : bool
  (and
    (match (& node.operation)
      [(NormalizeOperation.Arm) true]
      [_ false])
    (= (array-length node.children) 2)))

;; Whether a pattern binder from `first` on takes a move-only part of the
;; owned box contents at `position`.
(define (normalize-boxed-moves?
  [state : (& state NormalizeState)]
  [places : (& places (__tl_dyn-array i64))]
  [first : i64]
  [position : i64]) : bool
  (let
    [index : i64 first]
    [found : bool false]
    (while (and (not found) (< index (array-length state.pattern-binders)))
      (when
        (and
          (= (array-ref state.pattern-positions index) position)
          (array-ref state.pattern-boxed index)
          (not
            (normalize-copy-type?
              state
              (array-ref state.body.places (array-ref places (- index first))).type.index)))
        (set! found true))
      (set! index (+ index 1)))
    found))

;; Whether `index` is the first pattern binder from `first` on at the boxed
;; `position`.
(define (normalize-boxed-first?
  [state : (& state NormalizeState)]
  [first : i64]
  [index : i64]
  [position : i64]) : bool
  (let
    [cursor : i64 first]
    [found : i64 -1]
    (while (and (< found 0) (< cursor index))
      (when
        (and
          (= (array-ref state.pattern-positions cursor) position)
          (array-ref state.pattern-boxed cursor))
        (set! found cursor))
      (set! cursor (+ cursor 1)))
    (< found 0)))

;; The arm's bindings, in pattern order from `first`: a by-value binder takes
;; its position (a copy, or a move that leaves the position empty); a borrowed
;; binder is a reference derived from the scrutinee reference.
(define (normalize-pattern-bindings!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [first : i64]
  [block : i64]
  ;; False for a binding or-pattern's later candidates: the first declared
  ;; the binders, and each candidate initializes them on its own path.
  [declare? : bool]
  [source : (& source own.OwnershipSource)]) : NormalizeUnit
  (let
    [index : i64 first]
    ;; Every binder's place, registered before any is bound.
    [places : (__tl_dyn-array i64)
      (let
        [out : (__tl_dyn-array i64) (__tl_make-array i64 0)]
        [cursor : i64 first]
        (while (< cursor (array-length state.pattern-binders))
          (begin
            (__tl_array-push!
              out
              (try
                (normalize-binder!
                  state
                  store
                  lease
                  (typed.TypedBinderId
                    (typed.typed-handle-copy
                      (& (array-ref state.pattern-binders cursor).handle))))))
            (set! cursor (+ cursor 1))))
        out)]
    (while (< index (array-length state.pattern-binders))
      (let
        [position : i64 (array-ref state.pattern-positions index)]
        [place : i64 (array-ref places (- index first))]
        (when declare? (try (normalize-initializer! state place)))
        ;; At owned box contents: when a binder takes a move-only part,
        ;; the pattern moves the contents out of the box, consuming it once
        ;; and handing each binder its part; otherwise each binder reads
        ;; the box for its Copy part. Then initialize.
        (if (and (>= position 0) (array-ref state.pattern-boxed index))
          (begin
            (cond
              [(not
                  (normalize-boxed-moves? (& state) (& places) first position))
                (try
                  (normalize-emit!
                    state
                    block
                    (own.OwnershipOperation.Read
                      (normalize-place-id (& state) position))
                    source))]
              [(normalize-boxed-first? (& state) first index position)
                (try
                  (normalize-emit!
                    state
                    block
                    (own.OwnershipOperation.Consume
                      (normalize-place-id (& state) position))
                    source))]
              [else unit])
            (try
              (normalize-emit!
                state
                block
                (own.OwnershipOperation.Assign
                  (normalize-place-id (& state) place))
                source))
            ;; The binder takes the loans the box contents hold, as a part
            ;; moved out of the box does.
            (try (normalize-note-flow! state position place)))
          (if (< position 0)
            (begin
              (try
                (normalize-emit!
                  state
                  block
                  (own.OwnershipOperation.Assign
                    (normalize-place-id (& state) place))
                  source))
              (try
                (normalize-note-flow!
                  state
                  (array-ref state.pattern-sources index)
                  place)))
            (try (normalize-transfer! state block position place source))))
        (set! index (+ index 1))))
    (NormalizeUnit.Ok unit)))

;; Where an arm's body starts and where the next arm tests.
(defstruct NormalizeArmEntry
  (block i64)
  ;; -1 after an irrefutable arm.
  (next i64))

(defenum NormalizeArmEntryResult
  (Ok NormalizeArmEntry)
  (Err OwnershipNormalizeFailure))

;; An arm's pattern test and bindings, from `active`. A binding or-pattern
;; tests its candidates in turn: each binds the arm's binders from its own
;; positions in a block of its own, and all of them join where the body
;; starts.
(define (normalize-arm-entry!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [borrowed? : bool]
  [scrutinee : i64]
  [active : i64]
  [first : i64]
  [depth : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeArmEntryResult
  (let
    [node : NormalizeNode (try (normalize-node! state store lease id))]
    [alternatives? : bool
      (match (& node.operation)
        [(NormalizeOperation.Pattern (NormalizePattern.Alternatives)) true]
        [_ false])]
    (if alternatives?
      (let
        [body : i64 (try (normalize-block! state source))]
        [test-block : i64 active]
        ;; By value, child 0 forms the arm's position, which each candidate
        ;; forms again for itself.
        [candidate : i64
          (if borrowed?
            0
            (begin
              (try
                (normalize-walk!
                  state
                  store
                  lease
                  (normalize-child-id (& node) 0)
                  active
                  depth))
              1))]
        (while (< candidate (array-length node.children))
          (let
            [mark : i64 (array-length state.pattern-binders)]
            [step : NormalizeArmEntry
              (try
                (normalize-arm-candidate!
                  state
                  store
                  lease
                  (normalize-child-id (& node) candidate)
                  borrowed?
                  scrutinee
                  test-block
                  mark
                  (=
                    candidate
                    (if borrowed?
                      0
                      1))
                  depth
                  source))]
            ;; A later candidate after one that matches everything is
            ;; unreachable (typing rejects it).
            (when
              (and
                (< step.next 0)
                (< (+ candidate 1) (array-length node.children)))
              (return
                (NormalizeArmEntryResult.Err
                  (OwnershipNormalizeFailure.Structural
                    "ownership normalization: unreachable or-pattern candidate"))))
            (try
              (normalize-terminate!
                state
                step.block
                (own.OwnershipTerminator.Goto
                  (normalize-block-id (& state) body))))
            (set! test-block step.next)
            (set! candidate (+ candidate 1))))
        (try (normalize-retain-node! state node -1))
        (NormalizeArmEntryResult.Ok (NormalizeArmEntry body test-block)))
      (match (normalize-arm-test!
        state
        (try
          (normalize-pattern-node!
            state
            store
            lease
            node
            borrowed?
            scrutinee
            active
            depth))
        active
        source)
        [(NormalizeArmEntryResult.Err failure)
          (NormalizeArmEntryResult.Err failure)]
        [(NormalizeArmEntryResult.Ok entry)
          (try
            (normalize-pattern-bindings!
              state
              store
              lease
              first
              entry.block
              true
              source))
          (NormalizeArmEntryResult.Ok entry)]))))

;; One candidate of a binding or-pattern: its test from `active`, then its
;; bindings in the block it matches into.
(define (normalize-arm-candidate!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [id : typed.TypedOccurrenceId]
  [borrowed? : bool]
  [scrutinee : i64]
  [active : i64]
  [first : i64]
  [declare? : bool]
  [depth : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeArmEntryResult
  (match (normalize-arm-test!
    state
    (try
      (normalize-pattern!
        state
        store
        lease
        id
        borrowed?
        scrutinee
        active
        (+ depth 1)))
    active
    source)
    [(NormalizeArmEntryResult.Err failure)
      (NormalizeArmEntryResult.Err failure)]
    [(NormalizeArmEntryResult.Ok entry)
      (try
        (normalize-pattern-bindings!
          state
          store
          lease
          first
          entry.block
          declare?
          source))
      (NormalizeArmEntryResult.Ok entry)]))

;; A refutable pattern (1) branches from `active` on its test into a block of
;; its own, else into the next test's; an irrefutable one stays in `active`.
(define (normalize-arm-test!
  [state : (&mut state NormalizeState)]
  [refutable : i64]
  [active : i64]
  [source : (& source own.OwnershipSource)]) : NormalizeArmEntryResult
  (if (= refutable 1)
    (let
      [matched : i64 (try (normalize-block! state source))]
      [next : i64 (try (normalize-block! state source))]
      [test : NormalizeValue (try (normalize-value! state active 1 source))]
      (try
        (normalize-terminate!
          state
          active
          (own.OwnershipTerminator.Branch
            (normalize-place-id (& state) test.place)
            (normalize-block-id (& state) matched)
            (normalize-block-id (& state) next))))
      (NormalizeArmEntryResult.Ok (NormalizeArmEntry matched next)))
    (NormalizeArmEntryResult.Ok (NormalizeArmEntry active -1))))

;; --- Reassigned reference bindings (location-sensitive origins, #8449) -----
;;
;; Origins are solved per place, so a reference binding assigned twice holds
;; both values' loans everywhere. A read of the binding (a copy or move out of
;; it, or a recorded use) holds only the loans of the definitions reaching it:
;; each read's flow edge, and each use, is redirected to the value places of
;; its reaching definitions (copies or moves into the whole binding), found by
;; a reaching-definitions pass over the blocks. A binding with an origin noted
;; on it directly, with any incoming flow edge besides the one each such
;; definition records (a store through a reference to it, a field write), or
;; borrowed anywhere (a call may store through the borrow, which relates only
;; regions), keeps its per-place origin (conservative); so does any read not
;; matched to an instruction. A redirected read keeps its own place, so a
;; field read still relates the field's lifetimes (`normalize-note-redirect!`).
;; Whether `loan` is in the union of the rows of `alt-places[start..start+count)`.
(define (normalize-alt-row-has?
  [bits : (& bits (__tl_dyn-array bool))]
  [width : i64]
  [places : (& places (__tl_dyn-array i64))]
  [start : i64]
  [count : i64]
  [loan : i64]) : bool
  (let
    [at : i64 start]
    [found : bool false]
    (while (and (not found) (< at (+ start count)))
      (when
        (array-ref bits (+ (* (array-ref places at) width) loan))
        (set! found true))
      (set! at (+ at 1)))
    found))

;; The number of successors of block `block`.
(define (normalize-block-successor-count
  [state : (& state NormalizeState)]
  [block : i64]) : i64
  (match (& (array-ref state.body.blocks block).terminator)
    [(own.OwnershipTerminator.Goto _) 1]
    [(own.OwnershipTerminator.Branch _ _ _) 2]
    [_ 0]))

;; Successor `at` of block `block`.
(define (normalize-block-successor
  [state : (& state NormalizeState)]
  [block : i64]
  [at : i64]) : i64
  (match (& (array-ref state.body.blocks block).terminator)
    [(own.OwnershipTerminator.Goto target) target.index]
    [(own.OwnershipTerminator.Branch _ yes no)
      (if (= at 0)
        yes.index
        no.index)]
    [_ -1]))

;; The root place an operation copies or moves into as a whole (the
;; destination is a root), or -1; `source` receives the source's root.
(define (normalize-whole-transfer-target
  [state : (& state NormalizeState)]
  [operation : (& operation own.OwnershipOperation)]
  [source : (&mut source i64)]) : i64
  (match operation
    [(or (own.OwnershipOperation.Copy from to)
         (own.OwnershipOperation.Move from to))
      (if (<
        (own.ownership-parent (& (array-ref state.body.places to.index)))
        0)
        (begin
          (set! (deref source) (normalize-place-root state from.index))
          to.index)
        -1)]
    [_ -1]))

;; The root place an operation reads by copy or move, or -1; `target`
;; receives the destination's root.
(define (normalize-transfer-source
  [state : (& state NormalizeState)]
  [operation : (& operation own.OwnershipOperation)]
  [target : (&mut target i64)]) : i64
  (match operation
    [(or (own.OwnershipOperation.Copy from to)
         (own.OwnershipOperation.Move from to))
      (set! (deref target) (normalize-place-root state to.index))
      (normalize-place-root state from.index)]
    [_ -1]))

(define (normalize-split-reassigned!
  [state : (&mut state NormalizeState)]
  [alt-start : (&mut alt-start (__tl_dyn-array i64))]
  [alt-count : (&mut alt-count (__tl_dyn-array i64))]
  [alt-places : (&mut alt-places (__tl_dyn-array i64))]) : NormalizeUnit
  (let
    [blocks : i64 (array-length state.body.blocks)]
    [places : i64 (array-length state.body.places)]
    ;; Definitions: (place, block, index, value) in block order.
    [def-place : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [def-block : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [def-index : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [def-value : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [def-total : (__tl_dyn-array i64) (__tl_make-array i64 places)]
    [flow-total : (__tl_dyn-array i64) (__tl_make-array i64 places)]
    [opaque : (__tl_dyn-array bool) (__tl_make-array bool places)]
    [block : i64 0]
    (try (normalize-charge! state 0 (* 3 places) 0))
    (let
      [at : i64 0]
      (while (< at places)
        (set! (array-ref def-total at) 0)
        (set! (array-ref flow-total at) 0)
        (set! (array-ref opaque at) false)
        (set! at (+ at 1))))
    ;; Every flow edge into a place; a whole definition accounts for one. A
    ;; borrowed place may also be written through the borrow (a call storing
    ;; through its `&mut` argument relates only regions, no flow), so it is
    ;; never split.
    (let
      [at : i64 0]
      (try (normalize-charge! state 0 (array-length state.flow-to) 0))
      (while (< at (array-length state.flow-to))
        (let
          [to : i64 (array-ref state.flow-to at)]
          [from : i64 (array-ref state.flow-from at)]
          (when
            (and (>= to 0) (< to places))
            (set! (array-ref flow-total to) (+ (array-ref flow-total to) 1)))
          (when
            (and (array-ref state.flow-contents at) (>= from 0) (< from places))
            (set! (array-ref opaque from) true)))
        (set! at (+ at 1))))
    ;; Origins noted on a place directly are not definitions it can split.
    (let
      [at : i64 0]
      (while (< at (array-length state.origin-places))
        (set! (array-ref opaque (array-ref state.origin-places at)) true)
        (set! at (+ at 1))))
    (while (< block blocks)
      (let
        [instructions : i64
          (array-length (array-ref state.body.blocks block).instructions)]
        [index : i64 0]
        (try (normalize-charge! state 0 instructions 0))
        (while (< index instructions)
          (let
            [operation : (& state own.OwnershipOperation)
              (&
                (array-ref
                  (array-ref state.body.blocks block).instructions
                  index).operation)]
            [value : i64 -1]
            [target : i64
              (normalize-whole-transfer-target (& state) operation (&mut value))]
            (when
              (and
                (>= target 0)
                (!= (normalize-reference-kind (& state) target) 0))
              (begin
                (__tl_array-push! def-place target)
                (__tl_array-push! def-block block)
                (__tl_array-push! def-index index)
                (__tl_array-push! def-value value)
                (set!
                  (array-ref def-total target)
                  (+ (array-ref def-total target) 1)))))
          (set! index (+ index 1))))
      (set! block (+ block 1)))
    (let
      [place : i64 0]
      [preds : NormalizePredecessors (normalize-block-predecessors (& state))]
      (while (< place places)
        (when
          (and
            (>= (array-ref def-total place) 2)
            (not (array-ref opaque place))
            ;; Some other operation writes it too.
            (= (array-ref flow-total place) (array-ref def-total place)))
          (try
            (normalize-split-place!
              state
              place
              (& preds)
              (& def-place)
              (& def-block)
              (& def-index)
              (& def-value)
              alt-start
              alt-count
              alt-places)))
        (set! place (+ place 1))))
    (NormalizeUnit.Ok unit)))

;; Predecessors of every block, flat: block `b`'s are `list` entries
;; `start[b]` up to `start[b + 1]`. No array holds arrays, so building it
;; allocates nothing per block.
(defstruct NormalizePredecessors
  (start (__tl_dyn-array i64))
  (list (__tl_dyn-array i64)))

(define (normalize-block-predecessors [state : (& state NormalizeState)]) : NormalizePredecessors
  (let
    [blocks : i64 (array-length state.body.blocks)]
    [start : (__tl_dyn-array i64) (__tl_make-array i64 (+ blocks 1))]
    [filled : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
    [block : i64 0]
    ;; Count block `next`'s predecessors in `start[next + 1]`, then sum.
    (while (< block blocks)
      (let
        [at : i64 0]
        (while (< at (normalize-block-successor-count state block))
          (let
            [next : i64 (normalize-block-successor state block at)]
            (when
              (and (>= next 0) (< next blocks))
              (set!
                (array-ref start (+ next 1))
                (+ (array-ref start (+ next 1)) 1))))
          (set! at (+ at 1))))
      (set! block (+ block 1)))
    (set! block 0)
    (while (< block blocks)
      (set!
        (array-ref start (+ block 1))
        (+ (array-ref start (+ block 1)) (array-ref start block)))
      (set! block (+ block 1)))
    (let
      [list : (__tl_dyn-array i64)
        (__tl_make-array i64 (array-ref start blocks))]
      (set! block 0)
      (while (< block blocks)
        (let
          [at : i64 0]
          (while (< at (normalize-block-successor-count state block))
            (let
              [next : i64 (normalize-block-successor state block at)]
              (when
                (and (>= next 0) (< next blocks))
                (set!
                  (array-ref
                    list
                    (+ (array-ref start next) (array-ref filled next)))
                  block)
                (set! (array-ref filled next) (+ (array-ref filled next) 1))))
            (set! at (+ at 1))))
        (set! block (+ block 1)))
      (NormalizePredecessors start list))))

;; Redirect the reads and uses of reassigned binding `place` to its reaching
;; definitions' values.
(define (normalize-split-place!
  [state : (&mut state NormalizeState)]
  [place : i64]
  [preds : (& preds NormalizePredecessors)]
  [def-place : (& def-place (__tl_dyn-array i64))]
  [def-block : (& def-block (__tl_dyn-array i64))]
  [def-index : (& def-index (__tl_dyn-array i64))]
  [def-value : (& def-value (__tl_dyn-array i64))]
  [alt-start : (&mut alt-start (__tl_dyn-array i64))]
  [alt-count : (&mut alt-count (__tl_dyn-array i64))]
  [alt-places : (&mut alt-places (__tl_dyn-array i64))]) : NormalizeUnit
  (let
    [blocks : i64 (array-length state.body.blocks)]
    ;; This place's definitions, as indices into the def arrays.
    [defs : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [at : i64 0]
    (while (< at (array-length def-place))
      (when (= (array-ref def-place at) place) (__tl_array-push! defs at))
      (set! at (+ at 1)))
    (let
      [count : i64 (array-length defs)]
      [entry : (__tl_dyn-array bool) (__tl_make-array bool (* blocks count))]
      [exit : (__tl_dyn-array bool) (__tl_make-array bool (* blocks count))]
      [last : (__tl_dyn-array i64) (__tl_make-array i64 blocks)]
      [changed : bool true]
      [block : i64 0]
      (try (normalize-charge! state 0 (* 2 blocks count) 0))
      ;; The last definition in each block (gen), or -1.
      (while (< block blocks)
        (set! (array-ref last block) -1)
        (set! block (+ block 1)))
      (set! at 0)
      (while (< at count)
        (set! (array-ref last (array-ref def-block (array-ref defs at))) at)
        (set! at (+ at 1)))
      (while changed
        (set! changed false)
        (set! block 0)
        (while (< block blocks)
          (let
            [p : i64 (array-ref preds.start block)]
            (try (normalize-charge! state 0 count 0))
            (while (< p (array-ref preds.start (+ block 1)))
              (let
                [pred : i64 (array-ref preds.list p)]
                [d : i64 0]
                (while (< d count)
                  (when
                    (and
                      (array-ref exit (+ (* pred count) d))
                      (not (array-ref entry (+ (* block count) d))))
                    (set! (array-ref entry (+ (* block count) d)) true)
                    (set! changed true))
                  (set! d (+ d 1))))
              (set! p (+ p 1)))
            (let
              [d : i64 0]
              (while (< d count)
                (let
                  [out : bool
                    (if (>= (array-ref last block) 0)
                      (= d (array-ref last block))
                      (array-ref entry (+ (* block count) d)))]
                  (when
                    (and out (not (array-ref exit (+ (* block count) d))))
                    (set! (array-ref exit (+ (* block count) d)) true)
                    (set! changed true)))
                (set! d (+ d 1)))))
          (set! block (+ block 1))))
      ;; Reads: a copy or move out of the place.
      (let
        [edge : i64 0]
        [edges : i64 (array-length state.flow-from)]
        (while (< edge edges)
          (when
            (and
              (= (array-ref state.flow-from edge) place)
              (not (array-ref state.flow-outlives edge))
              (not (array-ref state.flow-contents edge)))
            (let
              [to : i64 (array-ref state.flow-to edge)]
              [matched : bool false]
              ;; A read no definition reaches (a value bound without one)
              ;; keeps the binding's own origin.
              [unreached : bool false]
              [b : i64 0]
              (while (< b blocks)
                (let
                  [instructions : i64
                    (array-length (array-ref state.body.blocks b).instructions)]
                  [i : i64 0]
                  (while (< i instructions)
                    (let
                      [target : i64 -1]
                      [source : i64
                        (normalize-transfer-source
                          (& state)
                          (&
                            (array-ref
                              (array-ref state.body.blocks b).instructions
                              i).operation)
                          (&mut target))]
                      (when
                        (and (= source place) (= target to))
                        (let
                          [reaching : (__tl_dyn-array i64)
                            (normalize-reaching-at
                              (& entry)
                              count
                              (& defs)
                              def-block
                              def-index
                              b
                              i)]
                          [r : i64 0]
                          (set! matched true)
                          (when
                            (= (array-length reaching) 0)
                            (set! unreached true))
                          (while (< r (array-length reaching))
                            (try
                              (normalize-note-redirect!
                                state
                                (array-ref state.flow-from-place edge)
                                (array-ref
                                  def-value
                                  (array-ref defs (array-ref reaching r)))
                                (array-ref state.flow-to-place edge)))
                            (set! r (+ r 1))))))
                    (set! i (+ i 1))))
                (set! b (+ b 1)))
              (when
                (and matched (not unreached))
                (set! (array-ref state.flow-from edge) -1))))
          (set! edge (+ edge 1))))
      ;; Uses: the loans of the definitions reaching each.
      (let
        [use : i64 0]
        (while (< use (array-length state.use-places))
          (when
            (= (array-ref state.use-places use) place)
            (let
              [reaching : (__tl_dyn-array i64)
                (normalize-reaching-at
                  (& entry)
                  count
                  (& defs)
                  def-block
                  def-index
                  (array-ref state.use-blocks use)
                  (array-ref state.use-indices use))]
              [r : i64 0]
              (when
                (> (array-length reaching) 0)
                (set! (array-ref alt-start use) (array-length alt-places))
                (set! (array-ref alt-count use) (array-length reaching))
                (while (< r (array-length reaching))
                  (__tl_array-push!
                    alt-places
                    (array-ref
                      def-value
                      (array-ref defs (array-ref reaching r))))
                  (set! r (+ r 1))))))
          (set! use (+ use 1))))
      (NormalizeUnit.Ok unit))))

;; The definitions (indices into `defs`) reaching position `index` of `block`:
;; the last one before it in the block, else those reaching the block entry.
(define (normalize-reaching-at
  [entry : (& entry (__tl_dyn-array bool))]
  [count : i64]
  [defs : (& defs (__tl_dyn-array i64))]
  [def-block : (& def-block (__tl_dyn-array i64))]
  [def-index : (& def-index (__tl_dyn-array i64))]
  [block : i64]
  [index : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [local : i64 -1]
    [d : i64 0]
    (while (< d count)
      (when
        (and
          (= (array-ref def-block (array-ref defs d)) block)
          (< (array-ref def-index (array-ref defs d)) index))
        (set! local d))
      (set! d (+ d 1)))
    (if (>= local 0)
      (__tl_array-push! out local)
      (begin
        (set! d 0)
        (while (< d count)
          (when
            (array-ref entry (+ (* block count) d))
            (__tl_array-push! out d))
          (set! d (+ d 1)))))
    out))

(define (normalize-match!
  [state : (&mut state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [node : (& node NormalizeNode)]
  [borrowed? : bool]
  [block : i64]
  [depth : i64]) : NormalizeValueResult
  (let
    [scrutinee : NormalizeValue
      (try
        (normalize-walk!
          state
          store
          lease
          (normalize-child-id node 0)
          block
          depth))]
    [merge : i64 (try (normalize-block! state (& node.source)))]
    [result : i64
      (if (= node.type 13)
        -1
        (try (normalize-local! state node.type false (& node.source))))]
    [active : i64 scrutinee.block]
    [arm : i64 1]
    [reached? : bool false]
    ;; A diverging scrutinee is an exit: no arm is entered.
    (when
      (= scrutinee.type 13)
      (return
        (if (= node.type 13)
          (NormalizeValueResult.Ok scrutinee)
          (NormalizeValueResult.Err (normalize-type-error)))))
    ;; Matching a move-only module value by value would consume its
    ;; permanent place (SPEC global places).
    (when
      (and
        (>= scrutinee.block 0)
        (not borrowed?)
        (not (normalize-copy-type? (& state) scrutinee.type))
        (normalize-global-local?
          (& state)
          (array-ref state.body.places scrutinee.place).local.index))
      (return
        (NormalizeValueResult.Err
          (try
            (normalize-global-move-out state scrutinee.place (& node.source))))))
    (when
      (or
        (< scrutinee.block 0)
        ;; An unnamed element scrutinee (its place is the whole array).
        (!=
          (array-ref state.body.places scrutinee.place).type.index
          scrutinee.type)
        (and
          borrowed?
          (= (normalize-reference-kind (& state) scrutinee.place) 0)))
      (return
        (NormalizeValueResult.Err
          (OwnershipNormalizeFailure.Unsupported
            "ownership normalization: match scrutinee outside the subset"))))
    (while (< arm (array-length node.children))
      (let
        [arm-node : NormalizeNode
          (try
            (normalize-node! state store lease (normalize-child-id node arm)))]
        [first : i64 (array-length state.pattern-binders)]
        (unless
          (and (normalize-arm? (& arm-node)) (>= active 0))
          (return
            (NormalizeValueResult.Err
              (OwnershipNormalizeFailure.Structural
                "ownership normalization: match arm shape"))))
        (let
          [entry : NormalizeArmEntry
            (try
              (normalize-arm-entry!
                state
                store
                lease
                (normalize-child-id (& arm-node) 0)
                borrowed?
                scrutinee.place
                active
                first
                (+ depth 1)
                (& arm-node.source)))]
          [arm-block : i64 entry.block]
          [next : i64 entry.next]
          (let
            [body : NormalizeValue
              (try
                (normalize-walk-in-context!
                  state
                  store
                  lease
                  (normalize-child-id (& arm-node) 1)
                  arm-block
                  (+ depth 1)
                  0))]
            (unless
              (or (= body.type 13) (= body.type node.type))
              (return (NormalizeValueResult.Err (normalize-type-error))))
            (when
              (>= body.block 0)
              (begin
                (when
                  (>= result 0)
                  (try
                    (normalize-transfer!
                      state
                      body.block
                      body.place
                      result
                      (& node.source))))
                (try
                  (normalize-terminate!
                    state
                    body.block
                    (own.OwnershipTerminator.Goto
                      (normalize-block-id (& state) merge))))
                (set! reached? true))))
          (try (normalize-retain-node! state arm-node -1))
          (set! active next)
          (set! arm (+ arm 1)))))
    ;; A refutable last arm leaves a test failure the typechecker proved
    ;; unreachable (exhaustiveness); its block keeps the Abort terminator.
    ;; When every arm diverges the match does too, whatever type the
    ;; context gave it.
    (cond
      [(not reached?) (NormalizeValueResult.Ok (NormalizeValue 13 -1 -1))]
      [(= node.type 13) (NormalizeValueResult.Err (normalize-type-error))]
      [else (NormalizeValueResult.Ok (NormalizeValue node.type result merge))])))

;; The entry block issues every parameter loan before the body runs. Without
;; reference parameters the walk creates its own entry block.
(define (normalize-parameter-entry! [state : (&mut state NormalizeState)]) : NormalizeInt
  (if (= (array-length state.parameter-loans) 0)
    (NormalizeInt.Ok -1)
    (let
      [first : i64 (array-ref state.parameter-loans 0)]
      [source : own.OwnershipSource
        (try (normalize-loan-source-copy! state first))]
      [block : i64 (try (normalize-block! state (& source)))]
      [index : i64 0]
      (while (< index (array-length state.parameter-loans))
        (let
          [loan : i64 (array-ref state.parameter-loans index)]
          [loan-source : own.OwnershipSource
            (try (normalize-loan-source-copy! state loan))]
          (try
            (normalize-emit!
              state
              block
              (own.OwnershipOperation.Borrow
                (own.OwnershipLoanId
                  (typed.typed-body-copy (& state.body.id))
                  loan))
              (& loan-source)))
          (set! index (+ index 1))))
      (NormalizeInt.Ok block))))

;; --- Type-based regions (#8449) ---------------------------------------------
;;
;; Loans are attached to regions named in types, never to the place a
;; reference points to (Rust's NLL/Polonius method; docs/ownership-ir.md). A
;; region node is a lifetime name occurring in a root place's type:
;; `(root, name)`; a parameter's signature lifetime is one universal node
;; shared by every parameter and the return; each call adds one node per
;; formal lifetime of its callee. Every recorded value transfer relates the
;; nodes of its two types position by position with variance (`&mut T` makes
;; `T` invariant; a nominal argument has its declaration's variance, from
;; typing, and is invariant unless covariant), a reborrow relates by name to
;; its root's nodes, and each region outlives the references it lies
;; under, so a reference stored through any chain of `&mut` lands in the
;; region the target's own type names. A use of a root demands the loans of
;; all its nodes; every return demands the universal nodes'. Where a
;; reference points (a reborrow's parent, a dereference check) is read off a
;; second graph without shared universal nodes or outlives edges.
;; A type's lifetime positions in pre-order, each with whether the position is
;; invariant and the reference it lies under. Two types of the same shape
;; (equal up to names) line up index by index.
(defstruct NormalizeShapes
  (names NormalizeI64s)
  (invariant NormalizeBools)
  ;; Per position: the position (within its shape) of the reference it lies
  ;; under, or -1 (`NormalizeShapeOut`).
  (outers NormalizeI64s)
  (starts NormalizeI64s)
  (lens NormalizeI64s)
  ;; Per shape: whether its first name is a view's region tag (a value read
  ;; through a reference, which reaches the viewed memory), and whether it is
  ;; a reference's own outer region.
  (views NormalizeBools)
  (references NormalizeBools)
  ;; Per place: its shape, or -1 when its type is unknown.
  (place-shapes (__tl_dyn-array i64))
  ;; Per call operand (aligned with `call-operands`): the formal parameter's
  ;; shape, -1 for an indirect call's callee.
  (call-shapes NormalizeI64s)
  (call-ret-shapes NormalizeI64s)
  (return-shape i64)
  ;; The signature's lifetime names: universal regions.
  (universal (__tl_dyn-array i64))
  ;; Cache per typed type record: its shape id plus one (zero when not yet
  ;; computed), and that of its referent.
  (cache-plain (__tl_dyn-array i64))
  (cache-deref (__tl_dyn-array i64)))

(defenum NormalizeShapesResult
  (Ok NormalizeShapes)
  (Err OwnershipNormalizeFailure))

;; A shape position records its lifetime name, whether it is invariant, and
;; the position of the reference (or view) it lies under, or -1: that
;; reference's region is outlived by it (well-formedness).
(defstruct NormalizeShapeOut
  (names (__tl_dyn-array i64))
  (vars (__tl_dyn-array bool))
  (outers (__tl_dyn-array i64)))

(define (normalize-shape-push!
  [out : (&mut out NormalizeShapeOut)]
  [name : i64]
  [inv? : bool]
  [outer : i64]) : unit
  (__tl_array-push! out.names name)
  (__tl_array-push! out.vars inv?)
  (__tl_array-push! out.outers outer))

(define (normalize-shape-walk
  [variances : (& variances OwnershipNormalizeVariances)]
  [ty : ast.AstType]
  [inv? : bool]
  [out : (&mut out NormalizeShapeOut)]
  [outer : i64]
  [depth : i64]) : bool
  (if (>= depth 32)
    false
    (let
      [here : i64 (array-length out.names)]
      (match ty
        [(ast.AstType.Ref lifetime inner)
          (normalize-shape-push! out lifetime inv? outer)
          (normalize-shape-walk
            variances
            (ast.ty-node-get inner)
            inv?
            out
            here
            (+ depth 1))]
        [(ast.AstType.MutRef lifetime inner)
          (normalize-shape-push! out lifetime inv? outer)
          (normalize-shape-walk
            variances
            (ast.ty-node-get inner)
            true
            out
            here
            (+ depth 1))]
        [(ast.AstType.Region lifetime inner)
          (normalize-shape-push! out lifetime inv? outer)
          (normalize-shape-walk
            variances
            (ast.ty-node-get inner)
            inv?
            out
            here
            (+ depth 1))]
        [(ast.AstType.Invalidate lifetime inner)
          (normalize-shape-push! out lifetime true outer)
          (normalize-shape-walk
            variances
            (ast.ty-node-get inner)
            true
            out
            here
            (+ depth 1))]
        [(or (ast.AstType.EnumArgs name lifetimes)
             (ast.AstType.StructArgs name lifetimes))
          (normalize-shape-lifetimes
            variances
            name
            (ast.ast-lifetime-list-box-shared-view lifetimes)
            inv?
            out
            outer)
          true]
        [(ast.AstType.VarArgs _ lifetimes)
          (normalize-shape-lifetimes
            variances
            -1
            (ast.ast-lifetime-list-box-shared-view lifetimes)
            true
            out
            outer)
          true]
        [(ast.AstType.Tuple elems)
          (normalize-shape-list
            variances
            (ast.ast-type-list-box-shared-view elems)
            inv?
            out
            outer
            (+ depth 1))]
        ;; A function type's lifetimes are its own: nothing outlives through it.
        [(ast.AstType.Func args ret)
          (and
            (normalize-shape-list
              variances
              (ast.ast-type-list-box-shared-view args)
              true
              out
              -1
              (+ depth 1))
            (normalize-shape-walk
              variances
              (ast.ty-node-get ret)
              true
              out
              -1
              (+ depth 1)))]
        [(ast.AstType.Array elem _)
          (normalize-shape-walk
            variances
            (ast.ty-node-get elem)
            inv?
            out
            outer
            (+ depth 1))]
        [(ast.AstType.DynArray elem)
          (normalize-shape-walk
            variances
            (ast.ty-node-get elem)
            inv?
            out
            outer
            (+ depth 1))]
        [(ast.AstType.Box elem)
          (normalize-shape-walk
            variances
            (ast.ty-node-get elem)
            inv?
            out
            outer
            (+ depth 1))]
        [(ast.AstType.Slice elem)
          (normalize-shape-walk
            variances
            (ast.ty-node-get elem)
            inv?
            out
            outer
            (+ depth 1))]
        [_ true]))))

;; A nominal type's lifetime arguments: each is invariant unless declared
;; covariant (`name` -1 declares none) and in a covariant context.
(define (normalize-shape-lifetimes
  [variances : (& variances OwnershipNormalizeVariances)]
  [name : i64]
  [lifetimes : ast.AstLifetimeList]
  [inv? : bool]
  [out : (&mut out NormalizeShapeOut)]
  [outer : i64]) : unit
  (let
    [index : i64 0]
    (while (< index (ast.ast-lifetime-list-len (& lifetimes)))
      (normalize-shape-push!
        out
        (ast.ast-lifetime-list-get (& lifetimes) index -1)
        (or inv? (not (normalize-nominal-covariant? variances name index)))
        outer)
      (set! index (+ index 1)))))

(define (normalize-shape-list
  [variances : (& variances OwnershipNormalizeVariances)]
  [types : ast.AstTypeList]
  [inv? : bool]
  [out : (&mut out NormalizeShapeOut)]
  [outer : i64]
  [depth : i64]) : bool
  (let
    [index : i64 0]
    [complete : bool true]
    (while (< index (ast.ast-type-list-len (& types)))
      (unless
        (normalize-shape-walk
          variances
          (ast.ty-node-get
            (ast.ast-type-list-get (& types) index (ast.ast-type-id-fallback)))
          inv?
          out
          outer
          depth)
        (set! complete false))
      (set! index (+ index 1)))
    complete))

;; The referent type of a reference type, reached through containers of
;; references (an element of an array of references): the type a synthetic
;; referent place stands for. Unit when `ty` holds no reference.
(define (normalize-referent-ast [ty : ast.AstType] [depth : i64]) : ast.AstType
  (if (>= depth 32)
    ast.AstType.Unit
    (match ty
      [(or (ast.AstType.Ref _ inner) (ast.AstType.MutRef _ inner))
        (ast.ty-node-get inner)]
      [(ast.AstType.Region _ inner)
        (normalize-referent-ast (ast.ty-node-get inner) (+ depth 1))]
      [(or (ast.AstType.Array elem _) (ast.AstType.DynArray elem)
           (ast.AstType.Box elem) (ast.AstType.Slice elem))
        (normalize-referent-ast (ast.ty-node-get elem) (+ depth 1))]
      [_ ast.AstType.Unit])))

;; Append the shape of `ty`; returns its id. A type nested past the walk's
;; depth bound has no complete shape, and the body fails closed.
(define (normalize-shape-add!
  [shapes : (&mut shapes NormalizeShapes)]
  [variances : (& variances OwnershipNormalizeVariances)]
  [ty : ast.AstType]) : NormalizeInt
  (let
    [id : i64 shapes.starts.len]
    [out : NormalizeShapeOut
      (NormalizeShapeOut
        (__tl_make-array i64 0)
        (__tl_make-array bool 0)
        (__tl_make-array i64 0))]
    [index : i64 0]
    [view? : bool
      (match (& ty)
        [(ast.AstType.Region _ _) true]
        [_ false])]
    [reference? : bool
      (match (& ty)
        [(or (ast.AstType.Ref _ _) (ast.AstType.MutRef _ _)) true]
        [_ false])]
    (unless
      (normalize-shape-walk variances ty false (&mut out) -1 0)
      (return (NormalizeInt.Err OwnershipNormalizeFailure.Resource)))
    (normalize-i64s-push! (&mut shapes.starts) shapes.names.len)
    (normalize-i64s-push! (&mut shapes.lens) (array-length out.names))
    (normalize-bools-push! (&mut shapes.views) view?)
    (normalize-bools-push! (&mut shapes.references) reference?)
    (while (< index (array-length out.names))
      (normalize-i64s-push! (&mut shapes.names) (array-ref out.names index))
      (normalize-bools-push! (&mut shapes.invariant) (array-ref out.vars index))
      (normalize-i64s-push! (&mut shapes.outers) (array-ref out.outers index))
      (set! index (+ index 1)))
    (NormalizeInt.Ok id)))

;; The shape of typed type record `typed` (cached per record).
(define (normalize-typed-shape!
  [shapes : (&mut shapes NormalizeShapes)]
  [variances : (& variances OwnershipNormalizeVariances)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [record : i64]
  [deref? : bool]) : NormalizeInt
  (let
    [cached? : bool
      (and (>= record 0) (< record (array-length shapes.cache-plain)))]
    (when
      cached?
      (let
        [hit : i64
          (if deref?
            (array-ref shapes.cache-deref record)
            (array-ref shapes.cache-plain record))]
        (when (> hit 0) (return (NormalizeInt.Ok (- hit 1))))))
    (match (typed.typed-type-value-at! store lease record)
      [(typed.TypedTypeValueResult.Ok value)
        ;; A referent walk stopped at the depth bound gives `Unit`; the
        ;; reference it is reached through has this record's plain shape,
        ;; which fails.
        (let
          [added : NormalizeInt
            (if deref?
              (normalize-shape-add!
                shapes
                variances
                (normalize-referent-ast value 0))
              (normalize-shape-add! shapes variances value))]
          (match added
            [(NormalizeInt.Ok id)
              (when
                cached?
                (if deref?
                  (set! (array-ref shapes.cache-deref record) (+ id 1))
                  (set! (array-ref shapes.cache-plain record) (+ id 1))))
              (NormalizeInt.Ok id)]
            [(NormalizeInt.Err failure) (NormalizeInt.Err failure)]))]
      [(typed.TypedTypeValueResult.Err error)
        (NormalizeInt.Err (OwnershipNormalizeFailure.Typed error))])))

(define (normalize-shape-names-into!
  [shapes : (& shapes NormalizeShapes)]
  [shape : i64]
  [out : (&mut out (__tl_dyn-array i64))]) : unit
  (when
    (>= shape 0)
    (let
      [start : i64 (array-ref shapes.starts.items shape)]
      [index : i64 0]
      (while (< index (array-ref shapes.lens.items shape))
        (let
          [name : i64 (array-ref shapes.names.items (+ start index))]
          (unless (normalize-i64-member? out name) (__tl_array-push! out name)))
        (set! index (+ index 1))))))

(define (normalize-append-unique!
  [out : (&mut out (__tl_dyn-array i64))]
  [items : (& items (__tl_dyn-array i64))]) : unit
  (let
    [index : i64 0]
    (while (< index (array-length items))
      (unless
        (normalize-i64-member? out (array-ref items index))
        (__tl_array-push! out (array-ref items index)))
      (set! index (+ index 1)))))

(define (normalize-i64-member?
  [items : (& items (__tl_dyn-array i64))]
  [value : i64]) : bool
  (let
    [index : i64 0]
    (while (< index (array-length items))
      (when (= (array-ref items index) value) (return true))
      (set! index (+ index 1)))
    false))

;; Shapes for every place, call and the return type, and the universal names
;; (every lifetime a parameter's or the return type names).
(define (normalize-compute-shapes!
  [state : (& state NormalizeState)]
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [return-type : i64]) : NormalizeShapesResult
  (let
    [shapes : NormalizeShapes
      (NormalizeShapes
        (normalize-i64s)
        (normalize-bools)
        (normalize-i64s)
        (normalize-i64s)
        (normalize-i64s)
        (normalize-bools)
        (normalize-bools)
        (__tl_make-array i64 state.place-count)
        (normalize-i64s)
        (normalize-i64s)
        -1
        (__tl_make-array i64 0)
        (__tl_make-array i64 (array-length state.type-references))
        (__tl_make-array i64 (array-length state.type-references)))]
    [place : i64 0]
    [index : i64 0]
    (while (< place state.place-count)
      (let
        [record : i64 (array-ref state.place-typed place)]
        [through : i64 (array-ref state.place-deref place)]
        (set!
          (array-ref shapes.place-shapes place)
          (cond
            [(>= record 0)
              (match (normalize-typed-shape!
                (&mut shapes)
                (& state.variances)
                store
                lease
                record
                false)
                [(NormalizeInt.Ok id) id]
                [(NormalizeInt.Err failure)
                  (return (NormalizeShapesResult.Err failure))])]
            [(and (>= through 0) (>= (array-ref state.place-typed through) 0))
              (match (normalize-typed-shape!
                (&mut shapes)
                (& state.variances)
                store
                lease
                (array-ref state.place-typed through)
                true)
                [(NormalizeInt.Ok id) id]
                [(NormalizeInt.Err failure)
                  (return (NormalizeShapesResult.Err failure))])]
            [else -1])))
      (set! place (+ place 1)))
    ;; Calls: the callee signature's formal parameter and result shapes.
    (while (< index state.call-sigs.len)
      (match (typed.typed-type-value-at!
        store
        lease
        (array-ref state.call-sigs.items index))
        [(typed.TypedTypeValueResult.Ok signature)
          (match signature
            [(ast.AstType.Func params-box ret)
              (let
                [params : ast.AstTypeList
                  (ast.ast-type-list-box-shared-view params-box)]
                [count : i64 (array-ref state.call-counts.items index)]
                [first : i64
                  (if (array-ref state.call-indirect.items index)
                    1
                    0)]
                [operand : i64 0]
                (while (< operand count)
                  (let
                    [shape : i64
                      (if (and
                        (>= operand first)
                        (< (- operand first) (ast.ast-type-list-len (& params))))
                        (match (normalize-shape-add!
                          (&mut shapes)
                          (& state.variances)
                          (ast.ty-node-get
                            (ast.ast-type-list-get
                              (& params)
                              (- operand first)
                              (ast.ast-type-id-fallback))))
                          [(NormalizeInt.Ok id) id]
                          [(NormalizeInt.Err failure)
                            (return (NormalizeShapesResult.Err failure))])
                        -1)]
                    (normalize-i64s-push! (&mut shapes.call-shapes) shape))
                  (set! operand (+ operand 1)))
                (let
                  [shape : i64
                    (match (normalize-shape-add!
                      (&mut shapes)
                      (& state.variances)
                      (ast.ty-node-get ret))
                      [(NormalizeInt.Ok id) id]
                      [(NormalizeInt.Err failure)
                        (return (NormalizeShapesResult.Err failure))])]
                  (normalize-i64s-push! (&mut shapes.call-ret-shapes) shape)))]
            [_
              (let
                [operand : i64 0]
                (while (< operand (array-ref state.call-counts.items index))
                  (normalize-i64s-push! (&mut shapes.call-shapes) -1)
                  (set! operand (+ operand 1)))
                (normalize-i64s-push! (&mut shapes.call-ret-shapes) -1))])]
        [(typed.TypedTypeValueResult.Err error)
          (return
            (NormalizeShapesResult.Err (OwnershipNormalizeFailure.Typed error)))])
      (set! index (+ index 1)))
    ;; The universal names: those of every parameter binder's type and the
    ;; declared return type.
    (set! index 0)
    (while (< index (array-length state.binders))
      (when
        (array-ref state.binders index).parameter?
        (let
          [record : i64
            (array-ref state.place-typed (array-ref state.binders index).place)]
          (when
            (>= record 0)
            (match (normalize-typed-shape!
              (&mut shapes)
              (& state.variances)
              store
              lease
              record
              false)
              [(NormalizeInt.Ok id)
                (let
                  [names : (__tl_dyn-array i64) (__tl_make-array i64 0)]
                  (normalize-shape-names-into! (& shapes) id (&mut names))
                  (normalize-append-unique! (&mut shapes.universal) (& names)))]
              [(NormalizeInt.Err failure)
                (return (NormalizeShapesResult.Err failure))]))))
      (set! index (+ index 1)))
    (when
      (>= return-type 0)
      (match (normalize-typed-shape!
        (&mut shapes)
        (& state.variances)
        store
        lease
        return-type
        false)
        [(NormalizeInt.Ok id)
          (set! shapes.return-shape id)
          (let
            [names : (__tl_dyn-array i64) (__tl_make-array i64 0)]
            (normalize-shape-names-into! (& shapes) id (&mut names))
            (normalize-append-unique! (&mut shapes.universal) (& names)))]
        [(NormalizeInt.Err failure)
          (return (NormalizeShapesResult.Err failure))]))
    (NormalizeShapesResult.Ok shapes)))

;; Region nodes: one per universal name (key -1), per name of a region root's
;; type (key: the root place), and per formal name of a call (key -2 - call).
;; A root whose type is unknown gets one wildcard node (name -1) standing for
;; all of its regions.
(defstruct NormalizeNodes
  (keys NormalizeI64s)
  (names NormalizeI64s)
  ;; Per place: the first node of the root's own nodes and their count.
  (place-first (__tl_dyn-array i64))
  (place-count (__tl_dyn-array i64))
  (call-first (__tl_dyn-array i64))
  (call-count (__tl_dyn-array i64))
  (universal-first i64)
  (universal-count i64)
  ;; Per place: whether it is a parameter binder. Only a parameter's (and the
  ;; return's) signature lifetimes are the universal regions; any other root
  ;; whose type spells one has regions of its own, related to them only by
  ;; the transfers that reach them, as a Rust temporary gets a fresh region.
  (parameter? (__tl_dyn-array bool)))

(define (normalize-node-add!
  [nodes : (&mut nodes NormalizeNodes)]
  [key : i64]
  [name : i64]) : unit
  (normalize-i64s-push! (&mut nodes.keys) key)
  (normalize-i64s-push! (&mut nodes.names) name))

;; The node for lifetime `name` of key `key`, or -1.
(define (normalize-node-of
  [nodes : (& nodes NormalizeNodes)]
  [shapes : (& shapes NormalizeShapes)]
  [key : i64]
  [name : i64]) : i64
  (let
    [first : i64 -1]
    [count : i64 0]
    [index : i64 0]
    (when
      (and
        (or (= key -1) (and (>= key 0) (array-ref nodes.parameter? key)))
        (normalize-i64-member? shapes.universal name))
      (while (< index nodes.universal-count)
        (when
          (= (array-ref nodes.names.items (+ nodes.universal-first index)) name)
          (return (+ nodes.universal-first index)))
        (set! index (+ index 1)))
      (return -1))
    (cond
      [(>= key 0)
        (set! first (array-ref nodes.place-first key))
        (set! count (array-ref nodes.place-count key))]
      [(<= key -2)
        (set! first (array-ref nodes.call-first (- -2 key)))
        (set! count (array-ref nodes.call-count (- -2 key)))]
      [else unit])
    (set! index 0)
    (while (< index count)
      (let
        [name-at : i64 (array-ref nodes.names.items (+ first index))]
        (when (or (= name-at name) (= name-at -1)) (return (+ first index))))
      (set! index (+ index 1)))
    -1))

;; With `share?` a parameter's signature lifetimes are the universal nodes
;; every parameter and the return share; without it each parameter has nodes
;; of its own and only the return's are universal.
(define (normalize-build-nodes
  [state : (& state NormalizeState)]
  [shapes : (& shapes NormalizeShapes)]
  [share? : bool]) : NormalizeNodes
  (let
    [nodes : NormalizeNodes
      (NormalizeNodes
        (normalize-i64s)
        (normalize-i64s)
        (__tl_make-array i64 state.place-count)
        (__tl_make-array i64 state.place-count)
        (__tl_make-array i64 state.call-sigs.len)
        (__tl_make-array i64 state.call-sigs.len)
        0
        0
        (__tl_make-array bool state.place-count))]
    [index : i64 0]
    (while (< index (array-length state.binders))
      (when
        (and share? (array-ref state.binders index).parameter?)
        (set!
          (array-ref nodes.parameter? (array-ref state.binders index).place)
          true))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index (array-length shapes.universal))
      (normalize-node-add! (&mut nodes) -1 (array-ref shapes.universal index))
      (set! index (+ index 1)))
    (set! nodes.universal-count (array-length shapes.universal))
    (set! index 0)
    (while (< index state.place-count)
      (set! (array-ref nodes.place-first index) nodes.keys.len)
      (when
        (and
          (< (own.ownership-parent (& (array-ref state.body.places index))) 0)
          (< (array-ref state.region-roots index) 0))
        (let
          [shape : i64 (array-ref shapes.place-shapes index)]
          [names : (__tl_dyn-array i64) (__tl_make-array i64 0)]
          [at : i64 0]
          (if (< shape 0)
            (when
              (!= (normalize-reference-kind state index) 0)
              (normalize-node-add! (&mut nodes) index -1))
            (begin
              (normalize-shape-names-into! shapes shape (&mut names))
              (while (< at (array-length names))
                (unless
                  (and
                    (array-ref nodes.parameter? index)
                    (normalize-i64-member?
                      shapes.universal
                      (array-ref names at)))
                  (normalize-node-add! (&mut nodes) index (array-ref names at)))
                (set! at (+ at 1)))))))
      (set!
        (array-ref nodes.place-count index)
        (- nodes.keys.len (array-ref nodes.place-first index)))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index state.call-sigs.len)
      (let
        [names : (__tl_dyn-array i64) (__tl_make-array i64 0)]
        [operand : i64 0]
        [at : i64 0]
        (while (< operand (array-ref state.call-counts.items index))
          (normalize-shape-names-into!
            shapes
            (array-ref
              shapes.call-shapes.items
              (+ (array-ref state.call-starts.items index) operand))
            (&mut names))
          (set! operand (+ operand 1)))
        (normalize-shape-names-into!
          shapes
          (array-ref shapes.call-ret-shapes.items index)
          (&mut names))
        (set! (array-ref nodes.call-first index) nodes.keys.len)
        (while (< at (array-length names))
          (normalize-node-add! (&mut nodes) (- -2 index) (array-ref names at))
          (set! at (+ at 1)))
        (set!
          (array-ref nodes.call-count index)
          (- nodes.keys.len (array-ref nodes.call-first index))))
      (set! index (+ index 1)))
    nodes))

;; Region edges: `from -> to` means the loans of `from` flow into `to`.
(defstruct NormalizeRegionEdges
  (from NormalizeI64s)
  (to NormalizeI64s)
  ;; At most `limit` edges are built (the work budget left); past it the
  ;; graph is `exhausted` and the body fails closed.
  (limit i64)
  (exhausted bool)
  ;; An outlives edge (a reborrow's from the reference it went through, a
  ;; well-formedness one): it keeps those loans live, but they are not where
  ;; the target points.
  (outlives NormalizeBools))

(define (normalize-region-edge!
  [edges : (&mut edges NormalizeRegionEdges)]
  [from : i64]
  [to : i64]) : unit
  (normalize-region-edge-kind! edges from to false))

(define (normalize-region-edge-kind!
  [edges : (&mut edges NormalizeRegionEdges)]
  [from : i64]
  [to : i64]
  [outlives? : bool]) : unit
  (when
    (and (>= from 0) (>= to 0) (!= from to))
    (if (>= edges.from.len edges.limit)
      (set! edges.exhausted true)
      (begin
        (normalize-i64s-push! (&mut edges.from) from)
        (normalize-i64s-push! (&mut edges.to) to)
        (normalize-bools-push! (&mut edges.outlives) outlives?)))))

;; Every node of key `key` (a root's own, a call's, or for -1 the universal
;; nodes), into `out`.
(define (normalize-key-nodes-into!
  [nodes : (& nodes NormalizeNodes)]
  [shapes : (& shapes NormalizeShapes)]
  [key : i64]
  [shape : i64]
  [out : (&mut out (__tl_dyn-array i64))]) : unit
  (let
    [index : i64 0]
    (cond
      [(>= key 0)
        (while (< index (array-ref nodes.place-count key))
          (__tl_array-push! out (+ (array-ref nodes.place-first key) index))
          (set! index (+ index 1)))]
      [(<= key -2)
        (while (< index (array-ref nodes.call-count (- -2 key)))
          (__tl_array-push!
            out
            (+ (array-ref nodes.call-first (- -2 key)) index))
          (set! index (+ index 1)))]
      [else unit])
    ;; The universal names this shape mentions, for the return (key -1) and a
    ;; parameter's own regions.
    (when
      (and
        (>= shape 0)
        (or (= key -1) (and (>= key 0) (array-ref nodes.parameter? key))))
      (set! index 0)
      (while (< index (array-ref shapes.lens.items shape))
        (let
          [node : i64
            (normalize-node-of
              nodes
              shapes
              -1
              (array-ref
                shapes.names.items
                (+ (array-ref shapes.starts.items shape) index)))]
          (when
            (and (>= node 0) (not (normalize-i64-member? out node)))
            (__tl_array-push! out node)))
        (set! index (+ index 1))))))

;; An indirect call's callee value (root `root`, shape `shape`): its regions,
;; a closure's captures, relate both ways with every region of the call's
;; signature instance `key`. When the operand is a borrow of the closure, its
;; own outer region (the borrow's loan) is left out.
(define (normalize-relate-callee!
  [edges : (&mut edges NormalizeRegionEdges)]
  [nodes : (& nodes NormalizeNodes)]
  [shapes : (& shapes NormalizeShapes)]
  [root : i64]
  [shape : i64]
  [key : i64]) : unit
  (let
    [callee : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [call : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [outer : i64
      (if (and
        (>= shape 0)
        (array-ref shapes.references.items shape)
        (> (array-ref shapes.lens.items shape) 0))
        (normalize-node-of
          nodes
          shapes
          root
          (array-ref shapes.names.items (array-ref shapes.starts.items shape)))
        -1)]
    [i : i64 0]
    (normalize-key-nodes-into! nodes shapes root shape (&mut callee))
    (normalize-key-nodes-into! nodes shapes key -1 (&mut call))
    (while (and (< i (array-length callee)) (not edges.exhausted))
      (unless
        (= (array-ref callee i) outer)
        (let
          [j : i64 0]
          (while (< j (array-length call))
            (normalize-region-edge!
              edges
              (array-ref callee i)
              (array-ref call j))
            (normalize-region-edge!
              edges
              (array-ref call j)
              (array-ref callee i))
            (set! j (+ j 1)))))
      (set! i (+ i 1)))))

;; Relate every node of one side with every node of the other, both ways: a
;; transfer whose shapes do not line up.
(define (normalize-relate-all!
  [edges : (&mut edges NormalizeRegionEdges)]
  [nodes : (& nodes NormalizeNodes)]
  [shapes : (& shapes NormalizeShapes)]
  [from-key : i64]
  [from-shape : i64]
  [to-key : i64]
  [to-shape : i64]) : unit
  (let
    [left : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [right : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [i : i64 0]
    (normalize-key-nodes-into! nodes shapes from-key from-shape (&mut left))
    (normalize-key-nodes-into! nodes shapes to-key to-shape (&mut right))
    (while (and (< i (array-length left)) (not edges.exhausted))
      (let
        [j : i64 0]
        (while (< j (array-length right))
          (normalize-region-edge! edges (array-ref left i) (array-ref right j))
          (normalize-region-edge! edges (array-ref right j) (array-ref left i))
          (set! j (+ j 1))))
      (set! i (+ i 1)))))

;; Relate shape `from-shape` (positions from `from-skip` on) of key `from-key`
;; with `to-shape` (from `to-skip`) of `to-key`, position by position: a
;; covariant position flows from -> to, an invariant one both ways
;; (`both?` forces both ways: an identity). Shapes that do not line up
;; relate everything both ways.
(define (normalize-relate!
  [edges : (&mut edges NormalizeRegionEdges)]
  [nodes : (& nodes NormalizeNodes)]
  [shapes : (& shapes NormalizeShapes)]
  [from-key : i64]
  [from-shape : i64]
  [from-skip : i64]
  [to-key : i64]
  [to-shape : i64]
  [to-skip : i64]
  [both? : bool]) : unit
  (if (or
    (< from-shape 0)
    (< to-shape 0)
    (!=
      (- (array-ref shapes.lens.items from-shape) from-skip)
      (- (array-ref shapes.lens.items to-shape) to-skip)))
    (normalize-relate-all!
      edges
      nodes
      shapes
      from-key
      from-shape
      to-key
      to-shape)
    (let
      [count : i64 (- (array-ref shapes.lens.items from-shape) from-skip)]
      [fs : i64 (+ (array-ref shapes.starts.items from-shape) from-skip)]
      [ts : i64 (+ (array-ref shapes.starts.items to-shape) to-skip)]
      [index : i64 0]
      [mismatch : bool false]
      ;; An identity relates each position both ways whatever its variance (a
      ;; borrow's referent is invariant under `&mut` where the borrowed place
      ;; may be covariant); a directed transfer whose variances differ is two
      ;; different types.
      (while (and (not both?) (< index count))
        (when
          (!=
            (array-ref shapes.invariant.items (+ fs index))
            (array-ref shapes.invariant.items (+ ts index)))
          (set! mismatch true))
        (set! index (+ index 1)))
      (if mismatch
        (normalize-relate-all!
          edges
          nodes
          shapes
          from-key
          from-shape
          to-key
          to-shape)
        (begin
          (set! index 0)
          (while (< index count)
            (let
              [from : i64
                (normalize-node-of
                  nodes
                  shapes
                  from-key
                  (array-ref shapes.names.items (+ fs index)))]
              [to : i64
                (normalize-node-of
                  nodes
                  shapes
                  to-key
                  (array-ref shapes.names.items (+ ts index)))]
              (if (or (< from 0) (< to 0))
                (normalize-relate-all!
                  edges
                  nodes
                  shapes
                  from-key
                  from-shape
                  to-key
                  to-shape)
                (begin
                  (normalize-region-edge! edges from to)
                  (when
                    (or both? (array-ref shapes.invariant.items (+ fs index)))
                    (normalize-region-edge! edges to from)))))
            (set! index (+ index 1))))))))

;; A borrow `to-key` of a place of root `from-key` and shape `from-shape`: its
;; referent positions are the place's own regions. When the reference's type
;; does not spell all of them (a closure's captures), every one of the place's
;; regions is related both ways with the reference's inner regions and
;; outlives its outer one; the outer region, which holds the borrow's own
;; loan, is never identified with the borrowed place's.
(define (normalize-relate-borrow!
  [edges : (&mut edges NormalizeRegionEdges)]
  [nodes : (& nodes NormalizeNodes)]
  [shapes : (& shapes NormalizeShapes)]
  [from-key : i64]
  [from-shape : i64]
  [to-key : i64]
  [to-shape : i64]) : unit
  (if (and
    (>= from-shape 0)
    (>= to-shape 0)
    (=
      (array-ref shapes.lens.items from-shape)
      (- (array-ref shapes.lens.items to-shape) 1)))
    (normalize-relate!
      edges
      nodes
      shapes
      from-key
      from-shape
      0
      to-key
      to-shape
      1
      true)
    (let
      [place : (__tl_dyn-array i64) (__tl_make-array i64 0)]
      [reference : (__tl_dyn-array i64) (__tl_make-array i64 0)]
      [outer : i64
        (if (and (>= to-shape 0) (> (array-ref shapes.lens.items to-shape) 0))
          (normalize-node-of
            nodes
            shapes
            to-key
            (array-ref
              shapes.names.items
              (array-ref shapes.starts.items to-shape)))
          -1)]
      [i : i64 0]
      (normalize-key-nodes-into! nodes shapes from-key from-shape (&mut place))
      (normalize-key-nodes-into! nodes shapes to-key to-shape (&mut reference))
      (while (< i (array-length place))
        (let
          [j : i64 0]
          (while (< j (array-length reference))
            (if (= (array-ref reference j) outer)
              (normalize-region-edge-kind! edges (array-ref place i) outer true)
              (begin
                (normalize-region-edge!
                  edges
                  (array-ref place i)
                  (array-ref reference j))
                (normalize-region-edge!
                  edges
                  (array-ref reference j)
                  (array-ref place i))))
            (set! j (+ j 1))))
        (set! i (+ i 1))))))

;; A reborrow `to-key` made through a place of root `from-key`. Its type is a
;; projection of that root's type, so each of its lifetime names is the
;; root's region of that name (the typechecker instantiates projections with
;; the root's names): its outer region is bounded by the root's region of the
;; same name (an outlives edge; the typing picked the reference that bounds
;; it), and every inner name is that very region. A name the root's type does
;; not spell relates both ways with all of its nodes; a reborrow of unknown
;; type relates everything.
(define (normalize-relate-reborrow!
  [edges : (&mut edges NormalizeRegionEdges)]
  [nodes : (& nodes NormalizeNodes)]
  [shapes : (& shapes NormalizeShapes)]
  [from-key : i64]
  [from-shape : i64]
  [to-key : i64]
  [to-shape : i64]) : unit
  (if (< to-shape 0)
    (normalize-relate-all!
      edges
      nodes
      shapes
      from-key
      from-shape
      to-key
      to-shape)
    (let
      [start : i64 (array-ref shapes.starts.items to-shape)]
      [index : i64 0]
      [others : (__tl_dyn-array i64) (__tl_make-array i64 0)]
      (normalize-key-nodes-into!
        nodes
        shapes
        from-key
        (if (>= from-key 0)
          (array-ref shapes.place-shapes from-key)
          from-shape)
        (&mut others))
      (while (< index (array-ref shapes.lens.items to-shape))
        (let
          [name : i64 (array-ref shapes.names.items (+ start index))]
          [to : i64 (normalize-node-of nodes shapes to-key name)]
          [from : i64 (normalize-node-of nodes shapes from-key name)]
          (cond
            [(< to 0)
              (normalize-relate-all!
                edges
                nodes
                shapes
                from-key
                from-shape
                to-key
                to-shape)]
            [(and (>= from 0) (= index 0))
              (normalize-region-edge-kind! edges from to true)]
            [(>= from 0)
              (normalize-region-edge! edges from to)
              (normalize-region-edge! edges to from)]
            [else
              (let
                [at : i64 0]
                (while (< at (array-length others))
                  (normalize-region-edge-kind!
                    edges
                    (array-ref others at)
                    to
                    (= index 0))
                  (unless
                    (= index 0)
                    (normalize-region-edge! edges to (array-ref others at)))
                  (set! at (+ at 1))))]))
        (set! index (+ index 1))))))

;; The region edges of every recorded flow, borrow, reborrow, call and return.
(define (normalize-region-edges
  [state : (& state NormalizeState)]
  [shapes : (& shapes NormalizeShapes)]
  [nodes : (& nodes NormalizeNodes)]) : NormalizeRegionEdges
  (let
    [edges : NormalizeRegionEdges
      (NormalizeRegionEdges
        (normalize-i64s)
        (normalize-i64s)
        (- state.limits.work state.work)
        false
        (normalize-bools))]
    [index : i64 0]
    (while (< index state.flow-count)
      (when
        (>= (array-ref state.flow-from index) 0)
        (let
          [from : i64 (array-ref state.flow-from-place index)]
          [to : i64 (array-ref state.flow-to-place index)]
          ;; The flow's root, which a redirected read of a split binding
          ;; replaces with the definition value (`normalize-note-redirect!`).
          [from-key : i64
            (normalize-region-root state (array-ref state.flow-from index))]
          [to-key : i64 (normalize-region-root state to)]
          [from-shape : i64 (array-ref shapes.place-shapes from)]
          [to-shape : i64 (array-ref shapes.place-shapes to)]
          (cond
            ;; A borrow `to` of a view `from` reborrows the viewed memory.
            [(and
                (array-ref state.flow-contents index)
                (>= from-shape 0)
                (array-ref shapes.views.items from-shape))
              (normalize-relate-reborrow!
                (&mut edges)
                nodes
                shapes
                from-key
                from-shape
                to-key
                to-shape)]
            [(array-ref state.flow-contents index)
              (normalize-relate-borrow!
                (&mut edges)
                nodes
                shapes
                from-key
                from-shape
                to-key
                to-shape)]
            ;; A reborrow `to` through reference `from`.
            [(array-ref state.flow-outlives index)
              (normalize-relate-reborrow!
                (&mut edges)
                nodes
                shapes
                from-key
                from-shape
                to-key
                to-shape)]
            [else
              (normalize-relate!
                (&mut edges)
                nodes
                shapes
                from-key
                from-shape
                0
                to-key
                to-shape
                0
                false)])))
      (set! index (+ index 1)))
    ;; Calls: operands into the callee's formals, its formal result into the
    ;; result place. An indirect callee's own regions also reach the formals
    ;; they name (a closure's captures).
    (set! index 0)
    (while (< index state.call-sigs.len)
      (let
        [operand : i64 0]
        [key : i64 (- -2 index)]
        (while (< operand (array-ref state.call-counts.items index))
          (let
            [slot : i64 (+ (array-ref state.call-starts.items index) operand)]
            [place : i64 (array-ref state.call-operands.items slot)]
            [formal : i64 (array-ref shapes.call-shapes.items slot)]
            (when
              (>= place 0)
              (if (< formal 0)
                (normalize-relate-callee!
                  (&mut edges)
                  nodes
                  shapes
                  (normalize-region-root state place)
                  (array-ref shapes.place-shapes place)
                  key)
                (normalize-relate!
                  (&mut edges)
                  nodes
                  shapes
                  (normalize-region-root state place)
                  (array-ref shapes.place-shapes place)
                  0
                  key
                  formal
                  0
                  false))))
          (set! operand (+ operand 1)))
        (when
          (>= (array-ref state.call-results.items index) 0)
          (normalize-relate!
            (&mut edges)
            nodes
            shapes
            key
            (array-ref shapes.call-ret-shapes.items index)
            0
            (normalize-region-root
              state
              (array-ref state.call-results.items index))
            (array-ref
              shapes.place-shapes
              (array-ref state.call-results.items index))
            0
            false)))
      (set! index (+ index 1)))
    ;; Returned values into the declared return type's universal regions.
    (set! index 0)
    (while (< index state.return-places.len)
      (let
        [place : i64 (array-ref state.return-places.items index)]
        (when
          (>= place 0)
          (normalize-relate!
            (&mut edges)
            nodes
            shapes
            (normalize-region-root state place)
            (array-ref shapes.place-shapes place)
            0
            -1
            shapes.return-shape
            0
            false)))
      (set! index (+ index 1)))
    ;; Well-formedness of every root's, formal's and the return's type.
    (set! index 0)
    (while (< index state.place-count)
      (when
        (and
          (< (own.ownership-parent (& (array-ref state.body.places index))) 0)
          (< (array-ref state.region-roots index) 0))
        (normalize-shape-outlives!
          (&mut edges)
          nodes
          shapes
          index
          (array-ref shapes.place-shapes index)))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index state.call-sigs.len)
      (let
        [operand : i64 0]
        [key : i64 (- -2 index)]
        (while (< operand (array-ref state.call-counts.items index))
          (normalize-shape-outlives!
            (&mut edges)
            nodes
            shapes
            key
            (array-ref
              shapes.call-shapes.items
              (+ (array-ref state.call-starts.items index) operand)))
          (set! operand (+ operand 1)))
        (normalize-shape-outlives!
          (&mut edges)
          nodes
          shapes
          key
          (array-ref shapes.call-ret-shapes.items index)))
      (set! index (+ index 1)))
    (normalize-shape-outlives! (&mut edges) nodes shapes -1 shapes.return-shape)
    edges))

;; Well-formedness: in key `key`'s shape, each region outlives the reference
;; it lies under (`(&mut r (T s))` has `s` outliving `r`), so that reference
;; keeps the loans of the regions behind it, as a call result typed with `r`
;; does. These are outlives edges: they do not change where a reference
;; points.
(define (normalize-shape-outlives!
  [edges : (&mut edges NormalizeRegionEdges)]
  [nodes : (& nodes NormalizeNodes)]
  [shapes : (& shapes NormalizeShapes)]
  [key : i64]
  [shape : i64]) : unit
  (when
    (>= shape 0)
    (let
      [start : i64 (array-ref shapes.starts.items shape)]
      [index : i64 0]
      (while (< index (array-ref shapes.lens.items shape))
        (let
          [outer : i64 (array-ref shapes.outers.items (+ start index))]
          (when
            (>= outer 0)
            (normalize-region-edge-kind!
              edges
              (normalize-node-of
                nodes
                shapes
                key
                (array-ref shapes.names.items (+ start index)))
              (normalize-node-of
                nodes
                shapes
                key
                (array-ref shapes.names.items (+ start outer)))
              true)))
        (set! index (+ index 1))))))

;; Close node loan sets (rows of `words` 64-bit words) over the region edges,
;; leaving out the outlives edges unless `outlives?`: a worklist over the
;; edges by source node, revisiting a node only when its set grew.
(define (normalize-close-regions!
  [state : (&mut state NormalizeState)]
  [bits : (&mut bits (__tl_dyn-array i64))]
  [edges : (& edges NormalizeRegionEdges)]
  [count : i64]
  [words : i64]
  [outlives? : bool]) : NormalizeUnit
  (let
    [starts : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
    [fill : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
    [targets : (__tl_dyn-array i64) (__tl_make-array i64 edges.from.len)]
    [queue : (__tl_dyn-array i64) (__tl_make-array i64 (+ count 1))]
    [queued : (__tl_dyn-array bool) (__tl_make-array bool (+ count 1))]
    [head : i64 0]
    [pending : i64 count]
    [index : i64 0]
    (try (normalize-charge! state 0 (+ count edges.from.len) 0))
    (while (< index edges.from.len)
      (when
        (or outlives? (not (array-ref edges.outlives.items index)))
        (set!
          (array-ref starts (+ (array-ref edges.from.items index) 1))
          (+ (array-ref starts (+ (array-ref edges.from.items index) 1)) 1)))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index count)
      (set!
        (array-ref starts (+ index 1))
        (+ (array-ref starts (+ index 1)) (array-ref starts index)))
      (set! (array-ref fill index) (array-ref starts index))
      (set! (array-ref queue index) index)
      (set! (array-ref queued index) true)
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index edges.from.len)
      (when
        (or outlives? (not (array-ref edges.outlives.items index)))
        (let
          [from : i64 (array-ref edges.from.items index)]
          (set!
            (array-ref targets (array-ref fill from))
            (array-ref edges.to.items index))
          (set! (array-ref fill from) (+ (array-ref fill from) 1))))
      (set! index (+ index 1)))
    (while (> pending 0)
      (let
        [node : i64 (array-ref queue head)]
        [edge : i64 0]
        (set!
          head
          (if (= (+ head 1) (+ count 1))
            0
            (+ head 1)))
        (set! pending (- pending 1))
        (set! (array-ref queued node) false)
        (set! edge (array-ref starts node))
        (while (< edge (array-ref starts (+ node 1)))
          (let
            [target : i64 (array-ref targets edge)]
            [from : i64 (* node words)]
            [to : i64 (* target words)]
            [word : i64 0]
            [grew : bool false]
            (try (normalize-charge! state 0 words 0))
            (while (< word words)
              (let
                [old : i64 (array-ref bits (+ to word))]
                [new : i64 (bit-or old (array-ref bits (+ from word)))]
                (when
                  (!= new old)
                  (set! (array-ref bits (+ to word)) new)
                  (set! grew true)))
              (set! word (+ word 1)))
            (when
              (and grew (not (array-ref queued target)))
              (set! (array-ref queued target) true)
              (set!
                (array-ref
                  queue
                  (if (>= (+ head pending) (+ count 1))
                    (- (+ head pending) (+ count 1))
                    (+ head pending)))
                target)
              (set! pending (+ pending 1))))
          (set! edge (+ edge 1)))))
    (NormalizeUnit.Ok unit)))

;; --- Reference origins -----------------------------------------------------
;;
;; Each loan sits in the region nodes its borrow's type names, closed over the
;; region edges of every value transfer (`normalize-region-edges`). Each
;; recorded use of a root then becomes one MayUseLoan per loan of any of its
;; nodes, inserted before the using instruction. A reborrow's parent is the
;; single loan of its binder's outer region.
(define (normalize-solve-origins!
  [state : (&mut state NormalizeState)]
  [shapes : (& shapes NormalizeShapes)]) : NormalizeUnit
  (let
    [places : i64 (array-length state.body.places)]
    [loans : i64 (array-length state.body.loans)]
    [width : i64
      (if (> loans 0)
        loans
        1)]
    [index : i64 0]
    (when
      (or
        (= loans 0)
        (and
          (= (array-length state.use-places) 0)
          (= (array-length state.reborrow-loans) 0)
          (= (array-length state.deref-places) 0)))
      (return (NormalizeUnit.Ok unit)))
    (unless
      (<= places (/ 16777216 width))
      (return (NormalizeUnit.Err OwnershipNormalizeFailure.Resource)))
    (let
      ;; Per use, the value places a reassigned binding's use reads instead
      ;; (`normalize-split-reassigned!`).
      [alt-start : (__tl_dyn-array i64)
        (__tl_make-array i64 (array-length state.use-places))]
      [alt-count : (__tl_dyn-array i64)
        (__tl_make-array i64 (array-length state.use-places))]
      [alt-places : (__tl_dyn-array i64) (__tl_make-array i64 0)]
      (try
        (normalize-split-reassigned!
          state
          (&mut alt-start)
          (&mut alt-count)
          (&mut alt-places)))
      (let
        ;; Liveness: a use demands its root's regions, and signature regions
        ;; are universal, live to the exit. Where a reference points: each
        ;; parameter's regions are its own, since a value returned into a
        ;; signature region does not make a parameter of that region point at
        ;; it, and reborrows add no loans (`NormalizeRegionEdges`).
        [nodes : NormalizeNodes (normalize-build-nodes (& state) shapes true)]
        [edges : NormalizeRegionEdges
          (normalize-region-edges (& state) shapes (& nodes))]
        [aim-nodes : NormalizeNodes
          (normalize-build-nodes (& state) shapes false)]
        [aim-edges : NormalizeRegionEdges
          (normalize-region-edges (& state) shapes (& aim-nodes))]
        [count : i64 (+ nodes.keys.len aim-nodes.keys.len)]
        [words : i64 (/ (+ width 63) 64)]
        (unless
          (and
            (not edges.exhausted)
            (not aim-edges.exhausted)
            (<= (+ count 2) (/ 16777216 words)))
          (return (NormalizeUnit.Err OwnershipNormalizeFailure.Resource)))
        (try
          (normalize-charge!
            state
            0
            (+
              (* (+ count 2) words)
              (* 2 places width)
              edges.from.len
              aim-edges.from.len)
            0))
        (let
          [node-bits : (__tl_dyn-array i64)
            (try
              (normalize-region-loans!
                state
                shapes
                (& nodes)
                (& edges)
                words
                true))]
          [aimed : (__tl_dyn-array i64)
            (try
              (normalize-region-loans!
                state
                shapes
                (& aim-nodes)
                (& aim-edges)
                words
                false))]
          [live : (__tl_dyn-array bool) (__tl_make-array bool (* places width))]
          [pointed : (__tl_dyn-array bool)
            (__tl_make-array bool (* places width))]
          ;; Per place: the loans of all its root's regions (a use), and of
          ;; the region its outer reference names (where it points).
          (while (< index places)
            (let
              [all : (__tl_dyn-array i64)
                (normalize-place-nodes (& state) shapes (& nodes) index)]
              [outer : (__tl_dyn-array i64)
                (normalize-outer-nodes (& state) shapes (& aim-nodes) index)]
              [row : i64 (* index width)]
              (normalize-rows-or! (& node-bits) (& all) words (&mut live) row)
              (normalize-rows-or! (& aimed) (& outer) words (&mut pointed) row))
            (set! index (+ index 1)))
          (try (normalize-patch-reborrows! state (& pointed) width))
          (try (normalize-check-derefs! state (& pointed) width))
          (normalize-insert-loan-uses!
            state
            (& live)
            width
            (& alt-start)
            (& alt-count)
            (& alt-places)))))))

;; Per region node, its loans as a row of `words` 64-bit words: each loan
;; sits in the outer region of the reference it is issued into, closed over
;; `edges` (with or without the reborrow and well-formedness outlives edges).
(define (normalize-region-loans!
  [state : (&mut state NormalizeState)]
  [shapes : (& shapes NormalizeShapes)]
  [nodes : (& nodes NormalizeNodes)]
  [edges : (& edges NormalizeRegionEdges)]
  [words : i64]
  [outlives? : bool]) : NormalizeWords
  (let
    [count : i64 nodes.keys.len]
    [bits : (__tl_dyn-array i64) (__tl_make-array i64 (* (+ count 1) words))]
    [index : i64 0]
    (while (< index (array-length state.origin-places))
      (let
        [targets : (__tl_dyn-array i64)
          (normalize-outer-nodes
            (& state)
            shapes
            nodes
            (array-ref state.origin-places index))]
        [loan : i64 (array-ref state.origin-loans index)]
        [at : i64 0]
        (while (< at (array-length targets))
          (let
            [slot : i64 (+ (* (array-ref targets at) words) (shr loan 6))]
            (set!
              (array-ref bits slot)
              (bit-or (array-ref bits slot) (shl 1 (bit-and loan 63)))))
          (set! at (+ at 1))))
      (set! index (+ index 1)))
    (match (normalize-close-regions!
      state
      (&mut bits)
      edges
      count
      words
      outlives?)
      [(NormalizeUnit.Ok _) (NormalizeWords.Ok bits)]
      [(NormalizeUnit.Err failure) (NormalizeWords.Err failure)])))

;; OR the loan rows (of `words` words) of `nodes` into bool row `row` of
;; `out`.
(define (normalize-rows-or!
  [bits : (& bits (__tl_dyn-array i64))]
  [nodes : (& nodes (__tl_dyn-array i64))]
  [words : i64]
  [out : (&mut out (__tl_dyn-array bool))]
  [row : i64]) : unit
  (let
    [at : i64 0]
    (while (< at (array-length nodes))
      (let
        [base : i64 (* (array-ref nodes at) words)]
        [word : i64 0]
        (while (< word words)
          (let
            [value : i64 (array-ref bits (+ base word))]
            [bit : i64 0]
            (when
              (!= value 0)
              (while (< bit 64)
                (when
                  (!= (bit-and value (shl 1 bit)) 0)
                  (set! (array-ref out (+ row (+ (* word 64) bit))) true))
                (set! bit (+ bit 1)))))
          (set! word (+ word 1))))
      (set! at (+ at 1)))))

;; The region nodes a use of `place` demands: every node of its region root
;; and the universal nodes its type names; for the exit holder, every
;; universal node.
(define (normalize-place-nodes
  [state : (& state NormalizeState)]
  [shapes : (& shapes NormalizeShapes)]
  [nodes : (& nodes NormalizeNodes)]
  [place : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [index : i64 0]
    (if (= place state.exit-holder)
      (while (< index nodes.universal-count)
        (__tl_array-push! out (+ nodes.universal-first index))
        (set! index (+ index 1)))
      (let
        [root : i64 (normalize-region-root state place)]
        (normalize-key-nodes-into!
          nodes
          shapes
          root
          (array-ref shapes.place-shapes root)
          (&mut out))
        (normalize-key-nodes-into!
          nodes
          shapes
          root
          (array-ref shapes.place-shapes place)
          (&mut out))))
    out))

;; The region node(s) a reference place's outer lifetime names: where it
;; points. A place of unknown type stands for all its root's nodes.
(define (normalize-outer-nodes
  [state : (& state NormalizeState)]
  [shapes : (& shapes NormalizeShapes)]
  [nodes : (& nodes NormalizeNodes)]
  [place : i64]) : (__tl_dyn-array i64)
  (let
    [out : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [root : i64 (normalize-region-root state place)]
    [shape : i64 (array-ref shapes.place-shapes place)]
    (if (or (< shape 0) (= (array-ref shapes.lens.items shape) 0))
      (normalize-key-nodes-into! nodes shapes root shape (&mut out))
      (let
        [node : i64
          (normalize-node-of
            nodes
            shapes
            root
            (array-ref shapes.names.items (array-ref shapes.starts.items shape)))]
        (if (>= node 0)
          (__tl_array-push! out node)
          (normalize-key-nodes-into! nodes shapes root shape (&mut out)))))
    out))

;; Each dereference of a local reference binder went through the loan it was
;; initialized from; its solved origin must be exactly that loan.
(define (normalize-check-derefs!
  [state : (&mut state NormalizeState)]
  [bits : (& bits (__tl_dyn-array bool))]
  [width : i64]) : NormalizeUnit
  (let
    [index : i64 0]
    (while (< index (array-length state.deref-places))
      (let
        [row : i64 (* (array-ref state.deref-places index) width)]
        [expected : i64 (array-ref state.deref-loans index)]
        [loan : i64 0]
        (try (normalize-charge! state 0 width 0))
        (while (< loan width)
          (when
            (if (= loan expected)
              (not (array-ref bits (+ row loan)))
              (array-ref bits (+ row loan)))
            (return
              (NormalizeUnit.Err
                (OwnershipNormalizeFailure.Unsupported
                  "ownership normalization: dereference of a joined or reassigned reference"))))
          (set! loan (+ loan 1)))
        (set! index (+ index 1))))
    (NormalizeUnit.Ok unit)))

(define (normalize-patch-reborrows!
  [state : (&mut state NormalizeState)]
  [bits : (& bits (__tl_dyn-array bool))]
  [width : i64]) : NormalizeUnit
  (let
    [index : i64 0]
    (while (< index (array-length state.reborrow-loans))
      (let
        [child : i64 (array-ref state.reborrow-loans index)]
        [row : i64 (* (array-ref state.reborrow-places index) width)]
        [parent : i64 -1]
        [count : i64 0]
        [loan : i64 0]
        (while (< loan (array-length state.body.loans))
          (when
            (array-ref bits (+ row loan))
            (set! parent loan)
            (set! count (+ count 1)))
          (set! loan (+ loan 1)))
        ;; Several possible parents need a reborrow of a joined origin,
        ;; which is not represented; a later parent cannot precede it.
        (unless
          (and (= count 1) (< parent child))
          (return
            (NormalizeUnit.Err
              (OwnershipNormalizeFailure.Unsupported
                "ownership normalization: reborrow of a joined or later origin"))))
        (set!
          (array-ref state.body.loans child).place
          (own.ownership-place-id-copy
            (& (array-ref state.body.loans parent).place)))
        (set!
          (array-ref state.body.loans child).origin
          (own.OwnershipLoanOrigin.Parent
            (own.OwnershipLoanId
              (typed.typed-body-copy (& state.body.id))
              parent)))
        (set! index (+ index 1))))
    (NormalizeUnit.Ok unit)))

;; Per root: the root a reference made there by a borrow reaches its referent
;; through (`normalize-note-contents!`), or -1, also when borrows of several
;; roots meet there or the borrowed root is a synthetic referent (which has
;; the regions of the reference it stands behind, not its own).
(define (normalize-lenders [state : (& state NormalizeState)]) : (__tl_dyn-array
    i64)
  (let
    [places : i64 (array-length state.body.places)]
    [out : (__tl_dyn-array i64) (__tl_make-array i64 places)]
    [mixed : (__tl_dyn-array bool) (__tl_make-array bool places)]
    [index : i64 0]
    (while (< index places)
      (set! (array-ref out index) -1)
      (set! (array-ref mixed index) false)
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index state.flow-count)
      (let
        [from : i64 (array-ref state.flow-from index)]
        [to : i64 (array-ref state.flow-to index)]
        (when
          (and
            (array-ref state.flow-contents index)
            (>= from 0)
            (< from places)
            (>= to 0)
            (< to places)
            (!= from to)
            (not (array-ref mixed to)))
          (if (!= (normalize-region-root state from) from)
            (begin
              (set! (array-ref mixed to) true)
              (set! (array-ref out to) -1))
            (cond
              [(< (array-ref out to) 0) (set! (array-ref out to) from)]
              [(!= (array-ref out to) from)
                (set! (array-ref mixed to) true)
                (set! (array-ref out to) -1)]
              [else unit]))))
      (set! index (+ index 1)))
    out))

;; Rebuild each block once, inserting a use's MayUseLoan operations before the
;; instruction it was recorded at (or before the terminator). Uses of one block
;; were recorded in nondecreasing instruction order. A use names the root
;; whose value holds each loan: a reference made by a borrow holds its own
;; loan, while the loans of its referent are held by the borrowed root (the
;; regions are one), so they end where that root is overwritten whole before
;; the borrow, as in Rust, where a borrow is a use of the borrowed variable.
(define (normalize-insert-loan-uses!
  [state : (&mut state NormalizeState)]
  [bits : (& bits (__tl_dyn-array bool))]
  [width : i64]
  [alt-start : (& alt-start (__tl_dyn-array i64))]
  [alt-count : (& alt-count (__tl_dyn-array i64))]
  [alt-places : (& alt-places (__tl_dyn-array i64))]) : NormalizeUnit
  (let
    [blocks : i64 (array-length state.body.blocks)]
    [counts : (__tl_dyn-array i64) (__tl_make-array i64 (+ blocks 1))]
    [order : (__tl_dyn-array i64)
      (__tl_make-array i64 (array-length state.use-places))]
    [fill : (__tl_dyn-array i64) (__tl_make-array i64 (+ blocks 1))]
    [lenders : (__tl_dyn-array i64) (normalize-lenders (& state))]
    [index : i64 0]
    [block : i64 0]
    (try
      (normalize-charge!
        state
        0
        (+
          blocks
          (array-length state.use-places)
          (array-length state.body.places)
          state.flow-count)
        0))
    ;; Stable bucket sort of the recorded uses by block.
    (while (< index (array-length state.use-blocks))
      (set!
        (array-ref counts (+ (array-ref state.use-blocks index) 1))
        (+ (array-ref counts (+ (array-ref state.use-blocks index) 1)) 1))
      (set! index (+ index 1)))
    (set! block 0)
    (while (< block blocks)
      (set!
        (array-ref counts (+ block 1))
        (+ (array-ref counts (+ block 1)) (array-ref counts block)))
      (set! (array-ref fill block) (array-ref counts block))
      (set! block (+ block 1)))
    (set! index 0)
    (while (< index (array-length state.use-blocks))
      (let
        [owner : i64 (array-ref state.use-blocks index)]
        (set! (array-ref order (array-ref fill owner)) index)
        (set! (array-ref fill owner) (+ (array-ref fill owner) 1))
        (set! index (+ index 1))))
    (set! block 0)
    (while (< block blocks)
      (let
        [first : i64 (array-ref counts block)]
        [last : i64 (array-ref counts (+ block 1))]
        (when
          (< first last)
          (let
            [old : (__tl_dyn-array own.OwnershipInstruction)
              (replace!
                (array-ref state.body.blocks block).instructions
                (__tl_make-array own.OwnershipInstruction 0))]
            [cursor : i64 first]
            [position : i64 0]
            (set! (array-ref state.instruction-counts block) 0)
            (while (<= position (array-length old))
              (while (and
                (< cursor last)
                (=
                  (array-ref state.use-indices (array-ref order cursor))
                  position))
                (let
                  [use : i64 (array-ref order cursor)]
                  [row : i64 (* (array-ref state.use-places use) width)]
                  [loan : i64 0]
                  [source : own.OwnershipSource
                    (if (< position (array-length old))
                      (own.ownership-source-copy
                        (& (array-ref old position).source))
                      (own.ownership-source-copy
                        (& (array-ref state.body.blocks block).source)))]
                  (while (< loan (array-length state.body.loans))
                    (when
                      (if (> (array-ref alt-count use) 0)
                        (normalize-alt-row-has?
                          bits
                          width
                          alt-places
                          (array-ref alt-start use)
                          (array-ref alt-count use)
                          loan)
                        (array-ref bits (+ row loan)))
                      (let
                        [used : i64 (array-ref state.use-places use)]
                        [through : i64 (array-ref lenders used)]
                        ;; The root whose value holds the loan.
                        [holder : i64
                          (if (and
                            (>= through 0)
                            (= (array-ref alt-count use) 0)
                            (array-ref bits (+ (* through width) loan)))
                            through
                            used)]
                        (try (normalize-charge! state 1 1 0))
                        (normalize-instruction-append!
                          state
                          block
                          (own.OwnershipInstruction
                            (own.OwnershipOperation.MayUseLoan
                              (own.OwnershipLoanId
                                (typed.typed-body-copy (& state.body.id))
                                loan)
                              (normalize-place-id (& state) holder))
                            (own.ownership-source-copy (& source))))))
                    (set! loan (+ loan 1)))
                  (set! cursor (+ cursor 1))))
              (when
                (< position (array-length old))
                (normalize-instruction-append!
                  state
                  block
                  (own.OwnershipInstruction
                    (own.ownership-operation-copy
                      (& (array-ref old position).operation))
                    (own.ownership-source-copy
                      (& (array-ref old position).source)))))
              (set! position (+ position 1)))
            (normalize-trim-block! state block)
            (unless
              (= cursor last)
              (return
                (NormalizeUnit.Err
                  (OwnershipNormalizeFailure.Structural
                    "ownership normalization: unordered reference use"))))))
        (set! block (+ block 1))))
    (NormalizeUnit.Ok unit)))

;; The field name ids from a place's root to the place itself.
(define (normalize-place-fields
  [state : (& state NormalizeState)]
  [place : i64]) : (__tl_dyn-array i64)
  (let
    [reversed : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [fields : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [current : i64 place]
    (while (>=
      (own.ownership-parent (& (array-ref state.body.places current)))
      0)
      (begin
        (__tl_array-push! reversed (array-ref state.field-names current))
        (set!
          current
          (own.ownership-parent (& (array-ref state.body.places current))))))
    (set! current (- (array-length reversed) 1))
    (while (>= current 0)
      (begin
        (__tl_array-push! fields (array-ref reversed current))
        (set! current (- current 1))))
    fields))

;; The root place of a field place (the place itself for a root).
(define (normalize-place-root [state : (& state NormalizeState)] [place : i64]) : i64
  (let
    [current : i64 place]
    (while (>=
      (own.ownership-parent (& (array-ref state.body.places current)))
      0)
      (set!
        current
        (own.ownership-parent (& (array-ref state.body.places current)))))
    current))

(define (normalize-binder-name [state : (& state NormalizeState)] [place : i64]) : i64
  (let
    [name : i64 -1]
    [index : i64 0]
    (while (< index (array-length state.binders))
      (when
        (= (array-ref state.binders index).place place)
        (set! name (array-ref state.binders index).name))
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index (array-length state.referent-places))
      (when
        (= (array-ref state.referent-places index) place)
        (set! name (array-ref state.referent-names index)))
      (set! index (+ index 1)))
    ;; A local reference's opaque referent is named by the reference, one held
    ;; in a part (a field, an element) by the binder holding that part.
    (set! index 0)
    (while (and (< name 0) (< index (array-length state.opaque-places)))
      (when
        (= (array-ref state.opaque-places index) place)
        (set!
          name
          (normalize-binder-name
            state
            (normalize-place-root state (array-ref state.opaque-binders index)))))
      (set! index (+ index 1)))
    name))

;; --- Move diagnostics ------------------------------------------------------
;;
;; The core reports the first read of an empty place. When that place is a
;; source binder, the report names it and a move that left it empty: one that
;; reaches the failing read without passing a reinitialization. A failing move
;; that reaches itself through a back edge is a loop-carried owner. A failure
;; that fits neither keeps the core's own message.
;; A move of the place, a field of it, or a place containing it.
(define (normalize-moves-place?
  [body : (& body own.OwnershipBody)]
  [op : (& op own.OwnershipOperation)]
  [place : i64]) : bool
  (match op
    [(own.OwnershipOperation.Move source _)
      (own.ownership-overlap? body source.index place)]
    [(own.OwnershipOperation.Consume target)
      (own.ownership-overlap? body target.index place)]
    ;; An arena destroy or rewind ends the values it invalidates.
    [(own.OwnershipOperation.Invalidate target)
      (own.ownership-overlap? body target.index place)]
    [_ false]))

;; A write of the place or of a place containing it reinitializes it.
(define (normalize-writes-place?
  [body : (& body own.OwnershipBody)]
  [op : (& op own.OwnershipOperation)]
  [place : i64]) : bool
  (match op
    [(own.OwnershipOperation.Initialize target)
      (own.ownership-descendant? body place target.index)]
    [(own.OwnershipOperation.Assign target)
      (own.ownership-descendant? body place target.index)]
    [(own.OwnershipOperation.Copy _ dest)
      (own.ownership-descendant? body place dest.index)]
    [(own.OwnershipOperation.Move _ dest)
      (own.ownership-descendant? body place dest.index)]
    [_ false]))

;; Scan one block from `start`: 1 when the target position is reached, 2 when
;; a write to the place blocks this path first, 0 to continue at successors.
;; Position `(array-length instructions)` is the block's terminator.
(define (normalize-scan-block
  [body : (& body own.OwnershipBody)]
  [place : i64]
  [block : i64]
  [start : i64]
  [to-block : i64]
  [to-instruction : i64]) : i64
  (let
    [count : i64 (array-length (array-ref body.blocks block).instructions)]
    [index : i64 start]
    [result : i64 0]
    (while (and (= result 0) (<= index count))
      (begin
        (cond
          [(and (= block to-block) (= index to-instruction)) (set! result 1)]
          [(and
              (< index count)
              (normalize-writes-place?
                body
                (&
                  (array-ref (array-ref body.blocks block).instructions index).operation)
                place))
            (set! result 2)]
          [else unit])
        (set! index (+ index 1))))
    result))

;; Whether control from just after the move at (from-block, from-instruction)
;; reaches the target position with the place still empty.
(define (normalize-move-reaches?
  [body : (& body own.OwnershipBody)]
  [place : i64]
  [from-block : i64]
  [from-instruction : i64]
  [to-block : i64]
  [to-instruction : i64]) : bool
  (let
    [blocks : i64 (array-length body.blocks)]
    [entered : (__tl_dyn-array bool) (__tl_make-array bool blocks)]
    [pending : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [found : bool false]
    [head : i64 0]
    [first : i64
      (normalize-scan-block
        body
        place
        from-block
        (+ from-instruction 1)
        to-block
        to-instruction)]
    (cond
      [(= first 1) (set! found true)]
      [(= first 0) (__tl_array-push! pending from-block)]
      [else unit])
    (while (and (not found) (< head (array-length pending)))
      (let
        [block : i64 (array-ref pending head)]
        [edge : i64 0]
        (set! head (+ head 1))
        (while (< edge 2)
          (let
            [next : i64
              (own.ownership-successor
                (& (array-ref body.blocks block).terminator)
                edge)]
            (when
              (and
                (not found)
                (>= next 0)
                (< next blocks)
                (not (array-ref entered next)))
              (set! (array-ref entered next) true)
              (match (normalize-scan-block
                body
                place
                next
                0
                to-block
                to-instruction)
                [1 (set! found true)]
                [0 (__tl_array-push! pending next)]
                [_ unit]))
            (set! edge (+ edge 1))))))
    found))

;; Whether `loan` is the shared reservation of a two-phase mutable borrow.
(define (normalize-reservation? [state : (& state NormalizeState)] [loan : i64]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (while (and (not found) (< index (array-length state.reservation-loans)))
      (when
        (= (array-ref state.reservation-loans index) loan)
        (set! found true))
      (set! index (+ index 1)))
    found))

;; The access kind of the operation a loan failure was reported at, or -1.
;; `place` is the failing place: a transfer into it writes it.
(define (normalize-access-kind
  [state : (& state NormalizeState)]
  [op : (& op own.OwnershipOperation)]
  [place : i64]) : i64
  (match op
    [(own.OwnershipOperation.Assign _) 0]
    [(own.OwnershipOperation.Initialize _) 0]
    [(own.OwnershipOperation.Invalidate _) 0]
    [(own.OwnershipOperation.Move _ dest)
      (if (= dest.index place)
        0
        1)]
    [(own.OwnershipOperation.Copy _ dest)
      (if (= dest.index place)
        0
        4)]
    [(own.OwnershipOperation.Consume _) 1]
    [(own.OwnershipOperation.Borrow loan)
      (cond
        [(normalize-store-loan? state loan.index) 0]
        [(or
            (own.ownership-loan-exclusive?
              (& (array-ref state.body.loans loan.index)))
            (normalize-reservation? state loan.index))
          2]
        [else 3])]
    ;; A store through a `&mut` reference reborrows its referent; the
    ;; reborrow is that store's assignment.
    [(own.OwnershipOperation.Reborrow loan)
      (if (normalize-store-loan? state loan.index)
        0
        2)]
    [(own.OwnershipOperation.Read _) 4]
    [(own.OwnershipOperation.AccessThrough _ _ access)
      (match access
        [(own.OwnershipAccess.Read) 4]
        [(own.OwnershipAccess.Write) 0])]
    [_ -1]))

;; Whether `op` stores a value into `place` itself.
(define (normalize-stores-place?
  [op : (& op own.OwnershipOperation)]
  [place : i64]) : bool
  (match op
    [(own.OwnershipOperation.Assign target) (= target.index place)]
    [(own.OwnershipOperation.Copy _ dest) (= dest.index place)]
    [(own.OwnershipOperation.Move _ dest) (= dest.index place)]
    [_ false]))

;; The element a loan failure at a store's borrow or reborrow names: the
;; store's literal element, else the element the failing place selects.
(define (normalize-failure-store-element
  [state : (& state NormalizeState)]
  [failure : (& failure own.OwnershipFailure)]
  [loan : i64]) : i64
  (let
    [stored : i64 (normalize-store-element state loan)]
    (if (>= stored 0)
      stored
      (normalize-element-at
        state
        failure.block
        failure.place
        (& failure.source)))))

(defenum NormalizeBorrowDiagnosticResult
  (Some OwnershipBorrowDiagnostic)
  (No))

(define (normalize-borrow-diagnostic
  [state : (& state NormalizeState)]
  [failure : (& failure own.OwnershipFailure)]) : NormalizeBorrowDiagnosticResult
  (let
    [body : (& state own.OwnershipBody) (& state.body)]
    [name : i64 -1]
    (unless
      (and
        (match (& failure.kind)
          [(own.OwnershipFailureKind.Loan) true]
          [_ false])
        (>= failure.place 0)
        (>= failure.conflicting-loan 0)
        (< failure.conflicting-loan (array-length body.loans))
        (>= failure.block 0)
        (< failure.block (array-length body.blocks))
        (>= failure.instruction 0)
        (<
          failure.instruction
          (array-length (array-ref body.blocks failure.block).instructions)))
      (return NormalizeBorrowDiagnosticResult.No))
    (set!
      name
      (normalize-binder-name state (normalize-place-root state failure.place)))
    (let
      [read : i64
        (normalize-access-kind
          state
          (&
            (array-ref
              (array-ref body.blocks failure.block).instructions
              failure.instruction).operation)
          failure.place)]
      ;; The initialization read before a Copy destination's store reports
      ;; as the assignment it belongs to.
      [access : i64
        (if (and
          (= read 4)
          (<
            (+ failure.instruction 1)
            (array-length (array-ref body.blocks failure.block).instructions))
          (normalize-stores-place?
            (&
              (array-ref
                (array-ref body.blocks failure.block).instructions
                (+ failure.instruction 1)).operation)
            failure.place))
          0
          read)]
      ;; An assignment a call made for a global it may assign (#7904).
      [effect : i64
        (match (&
          (array-ref
            (array-ref body.blocks failure.block).instructions
            failure.instruction).operation)
          [(own.OwnershipOperation.Assign _)
            (normalize-global-effect-at state failure.place (& failure.source))]
          [_ -1])]
      (if (or (< name 0) (< access 0))
        NormalizeBorrowDiagnosticResult.No
        (NormalizeBorrowDiagnosticResult.Some
          (OwnershipBorrowDiagnostic
            name
            (let
              [fields : (__tl_dyn-array i64)
                (normalize-place-fields state failure.place)]
              [element : i64
                (match (&
                  (array-ref
                    (array-ref body.blocks failure.block).instructions
                    failure.instruction).operation)
                  [(own.OwnershipOperation.Borrow loan)
                    (normalize-failure-store-element state failure loan.index)]
                  [(own.OwnershipOperation.Reborrow loan)
                    (normalize-failure-store-element state failure loan.index)]
                  [_
                    (normalize-element-at
                      state
                      failure.block
                      failure.place
                      (& failure.source))])]
              (when
                (>= element 0)
                (__tl_array-push! fields (normalize-element-field element)))
              fields)
            (if (>= effect 0)
              6
              access)
            (own.ownership-source-copy
              (& (array-ref body.loans failure.conflicting-loan).source))
            (if (>= effect 0)
              (array-ref state.effect-callees effect)
              -1)
            (if (>= effect 0)
              (array-ref state.effect-globals effect)
              -1)))))))

(defenum NormalizeMoveDiagnosticResult
  (Some OwnershipMoveDiagnostic)
  (No))

(define (normalize-move-diagnostic
  [state : (& state NormalizeState)]
  [failure : (& failure own.OwnershipFailure)]) : NormalizeMoveDiagnosticResult
  (let
    [body : (& state own.OwnershipBody) (& state.body)]
    [place : i64 failure.place]
    [block : i64 failure.block]
    [instruction : i64 failure.instruction]
    [name : i64 -1]
    (unless
      (and
        (match (& failure.kind)
          [(own.OwnershipFailureKind.Uninitialized) true]
          [_ false])
        (>= place 0)
        (< place (array-length body.places))
        (>= block 0)
        (< block (array-length body.blocks))
        (>= instruction 0)
        (<=
          instruction
          (array-length (array-ref body.blocks block).instructions)))
      (return NormalizeMoveDiagnosticResult.No))
    (set! name (normalize-binder-name state (normalize-place-root state place)))
    (when (< name 0) (return NormalizeMoveDiagnosticResult.No))
    (when
      (and
        (<
          instruction
          (array-length (array-ref body.blocks block).instructions))
        (or
          (normalize-moves-place?
            body
            (&
              (array-ref (array-ref body.blocks block).instructions instruction).operation)
            place)
          (normalize-affine-move-at? body block instruction place))
        (normalize-move-reaches? body place block instruction block instruction))
      (return
        (NormalizeMoveDiagnosticResult.Some
          (OwnershipMoveDiagnostic
            name
            (normalize-place-fields state place)
            true
            (own.ownership-source-copy (& failure.source))
            (normalize-place-fields state place)))))
    ;; An arena destroy or rewind that ended the value (or a value holding
    ;; it) is named first, as the invalidated binder; then a move.
    (match (normalize-move-search state place block instruction true)
      [(NormalizeMoveDiagnosticResult.Some diagnostic)
        (NormalizeMoveDiagnosticResult.Some diagnostic)]
      [(NormalizeMoveDiagnosticResult.No)
        (normalize-move-search state place block instruction false)])))

;; The first move (`invalidations?`: Invalidate) of `place` or of a place
;; overlapping it that reaches the failing position. An Invalidate of a place
;; containing `place` names that place.
;; An affine handle's move: a copy out of the place, then its Invalidate.
(define (normalize-affine-move-at?
  [body : (& body own.OwnershipBody)]
  [block : i64]
  [instruction : i64]
  [place : i64]) : bool
  (let
    [instructions : (& body (__tl_dyn-array own.OwnershipInstruction))
      (& (array-ref body.blocks block).instructions)]
    (and
      (< (+ instruction 1) (array-length instructions))
      (match (& (array-ref instructions instruction).operation)
        [(own.OwnershipOperation.Copy source _) (= source.index place)]
        [_ false])
      (match (& (array-ref instructions (+ instruction 1)).operation)
        [(own.OwnershipOperation.Invalidate target) (= target.index place)]
        [_ false]))))

(define (normalize-move-search
  [state : (& state NormalizeState)]
  [place : i64]
  [block : i64]
  [instruction : i64]
  [invalidations? : bool]) : NormalizeMoveDiagnosticResult
  (let
    [body : (& state own.OwnershipBody) (& state.body)]
    [move-block : i64 0]
    (while (< move-block (array-length body.blocks))
      (let
        [move-index : i64 0]
        (while (<
          move-index
          (array-length (array-ref body.blocks move-block).instructions))
          (let
            [op : (& body own.OwnershipOperation)
              (&
                (array-ref
                  (array-ref body.blocks move-block).instructions
                  move-index).operation)]
            [target : i64
              (match op
                [(own.OwnershipOperation.Invalidate ended) ended.index]
                [_ -1])]
            (when
              (and
                (if invalidations?
                  (and (>= target 0) (own.ownership-overlap? body target place))
                  (normalize-moves-place? body op place))
                (normalize-move-reaches?
                  body
                  place
                  move-block
                  move-index
                  block
                  instruction))
              (let
                ;; A use of a part of a moved or ended value names that
                ;; value (Rust: "use of moved value: `h`" for `h.fd`).
                [moved : i64
                  (match op
                    [(own.OwnershipOperation.Invalidate ended) ended.index]
                    [(own.OwnershipOperation.Move source _) source.index]
                    [(own.OwnershipOperation.Consume consumed) consumed.index]
                    [_ -1])]
                [named : i64
                  (if (and
                    (>= moved 0)
                    (own.ownership-descendant? body place moved))
                    moved
                    place)]
                (return
                  (NormalizeMoveDiagnosticResult.Some
                    (OwnershipMoveDiagnostic
                      (normalize-binder-name
                        state
                        (normalize-place-root state named))
                      (normalize-place-fields state named)
                      false
                      (own.ownership-source-copy
                        (&
                          (array-ref
                            (array-ref body.blocks move-block).instructions
                            move-index).source))
                      (normalize-place-fields
                        state
                        (if (>= moved 0)
                          moved
                          place)))))))
            (set! move-index (+ move-index 1))))
        (set! move-block (+ move-block 1))))
    NormalizeMoveDiagnosticResult.No))

(define (ownership-normalize!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [root : typed.TypedOccurrenceId]
  [return-type : typed.TypedTypeId]
  [classes : (__tl_dyn-array OwnershipNormalizeTypeClass)]
  [limits : OwnershipNormalizeLimits]) : OwnershipNormalizeResult
  (ownership-normalize-with-products!
    store
    lease
    root
    return-type
    classes
    (__tl_make-array OwnershipNormalizeProduct 0)
    (ownership-normalize-variances-empty)
    (ownership-normalize-global-writes-empty)
    limits))

;; A signature lifetime is the caller's region: whatever a body stores into a
;; place whose type names one outlives the call (Rust's `'a: 'body`). Every
;; return uses a dedicated holder whose regions are all the universal ones
;; (`normalize-solve-origins!`), so such loans stay live until the body
;; leaves. The holder is never assigned, so no overwrite ends that demand.
(define (normalize-note-exit-referent-uses!
  [state : (&mut state NormalizeState)]) : NormalizeUnit
  (when
    (< state.exit-holder 0)
    (let
      [source : own.OwnershipSource
        (own.ownership-source-copy (& (array-ref state.body.blocks 0).source))]
      (set! state.exit-holder (try (normalize-local! state 0 true (& source))))))
  (let
    [block : i64 0]
    (while (< block state.block-count)
      (when
        (normalize-block-returns? (& state) block)
        (try (normalize-charge! state 1 1 0))
        (normalize-reserve! state.use-blocks state.use-count i64)
        (normalize-reserve! state.use-indices state.use-count i64)
        (normalize-reserve! state.use-places state.use-count i64)
        (set! (array-ref state.use-blocks state.use-count) block)
        (set!
          (array-ref state.use-indices state.use-count)
          (array-ref state.instruction-counts block))
        (set! (array-ref state.use-places state.use-count) state.exit-holder)
        (set! state.use-count (+ state.use-count 1)))
      (set! block (+ block 1)))
    (NormalizeUnit.Ok unit)))

(define (normalize-block-returns?
  [state : (& state NormalizeState)]
  [block : i64]) : bool
  (match (& (array-ref state.body.blocks block).terminator)
    [(own.OwnershipTerminator.Return _) true]
    [(own.OwnershipTerminator.ReturnOwned _) true]
    [_ false]))

;; --- Parameter storage facts for lowering (#7901, #8449) -------------------
;;
;; A by-value aggregate parameter arrives as the address of its caller's
;; storage; lowering gives a parameter private callee storage only when the
;; body may write that storage in place (`tc-body-param-write-fact`). The
;; certified body answers it: a write is a `set!` or `replace!` of a place, or
;; a `(&mut place)` borrow (every store form and two-phase mutable argument
;; borrows its receiver so), whose root local shares storage with the
;; parameter. Lowering may elide the copy that initializes or assigns a local
;; from another binder's non-primitive place, so such locals join the source's
;; storage class; a pattern binder may be a view of its scrutinee, so it joins
;; every parameter's class; a raw address (`ptr-addr-of`) escapes the graph, so
;; it makes every parameter written. The answer over-approximates: a spurious
;; write only costs a copy.
;; The names of the parameters whose storage `body` may write, or the single
;; entry -1 for every parameter.
(define (ownership-normalized-written-parameters
  [output : (& output OwnershipNormalizedBody)]) : (__tl_dyn-array i64)
  (let
    [locals : i64 (array-length output.body.locals)]
    [classes : (__tl_dyn-array i64) (__tl_make-array i64 locals)]
    [written : (__tl_dyn-array bool) (__tl_make-array bool locals)]
    [by-handle : (__tl_dyn-array i64)
      (normalize-node-handle-table (& output.nodes))]
    [all : bool false]
    [index : i64 0]
    [names : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (while (< index locals)
      (set! (array-ref classes index) index)
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index (array-length output.nodes))
      (let
        [node : (& output NormalizeNode) (& (array-ref output.nodes index))]
        (match (& node.operation)
          [(NormalizeOperation.Primitive (typed.TypedPrimitive.PtrAddrOf))
            (set! all true)]
          [(or (NormalizeOperation.AssignPlace)
               (NormalizeOperation.ReplacePlace)
               (NormalizeOperation.Borrow true))
            (let
              [target : i64 (normalize-operand-local (& output.body) node 0)]
              (when
                (>= target 0)
                (set! (array-ref written target) true)
                (normalize-storage-alias!
                  output
                  (& by-handle)
                  node
                  1
                  target
                  (&mut classes))))]
          [(NormalizeOperation.Initialize binder)
            (let
              [target : i64 (normalize-binder-local output (& binder.handle))]
              (when
                (>= target 0)
                (normalize-storage-alias!
                  output
                  (& by-handle)
                  node
                  0
                  target
                  (&mut classes))))]
          [(NormalizeOperation.Pattern (NormalizePattern.Bind binder))
            (let
              [target : i64 (normalize-binder-local output (& binder.handle))]
              [at : i64 0]
              (when
                (>= target 0)
                (while (< at (array-length output.binders))
                  (when
                    (array-ref output.binders at).parameter?
                    (let
                      [parameter : i64
                        (normalize-place-local
                          (& output.body)
                          (array-ref output.binders at).place)]
                      (when
                        (>= parameter 0)
                        (normalize-class-union! (&mut classes) target parameter))))
                  (set! at (+ at 1)))))]
          [_ unit]))
      (set! index (+ index 1)))
    (if all
      (__tl_array-push! names -1)
      (let
        [class-written : (__tl_dyn-array bool) (__tl_make-array bool locals)]
        [at : i64 0]
        (while (< at locals)
          (when
            (array-ref written at)
            (set!
              (array-ref class-written (normalize-class-find (&mut classes) at))
              true))
          (set! at (+ at 1)))
        (set! at 0)
        (while (< at (array-length output.binders))
          (let
            [binder : (& output NormalizeBinder)
              (& (array-ref output.binders at))]
            (when
              binder.parameter?
              (let
                [local : i64
                  (normalize-place-local (& output.body) binder.place)]
                (when
                  (and
                    (>= local 0)
                    (array-ref
                      class-written
                      (normalize-class-find (&mut classes) local)))
                  (__tl_array-push! names binder.name)))))
          (set! at (+ at 1)))))
    names))

;; `node`'s value operand `slot`, when it reads another binder's
;; non-primitive place (a place read or a whole binder read), joins `target`'s
;; storage class: lowering may let the destination alias it.
(define (normalize-storage-alias!
  [output : (& output OwnershipNormalizedBody)]
  [by-handle : (& by-handle (__tl_dyn-array i64))]
  [node : (& node NormalizeNode)]
  [slot : i64]
  [target : i64]
  [classes : (&mut classes (__tl_dyn-array i64))]) : unit
  (when
    (< slot (array-length node.children))
    (let
      [handle : i64 (array-ref node.children slot).handle.index]
      [value : i64
        (if (and (>= handle 0) (< handle (array-length by-handle)))
          (array-ref by-handle handle)
          -1)]
      (when
        (and
          (>= value 0)
          (>= (array-ref output.nodes value).type normalize-first-value-type))
        (let
          [source : i64
            (match (& (array-ref output.nodes value).operation)
              [(NormalizeOperation.TakePlace)
                (normalize-operand-local
                  (& output.body)
                  (& (array-ref output.nodes value))
                  0)]
              [(NormalizeOperation.Read binder)
                (normalize-binder-local output (& binder.handle))]
              [_ -1])]
          (when (>= source 0) (normalize-class-union! classes target source)))))))

;; Node index by occurrence handle index (-1 where no node is retained).
(define (normalize-node-handle-table
  [nodes : (& nodes (__tl_dyn-array NormalizeNode))]) : (__tl_dyn-array i64)
  (let
    [limit : i64 0]
    [index : i64 0]
    (while (< index (array-length nodes))
      (when
        (>= (array-ref nodes index).handle.index limit)
        (set! limit (+ (array-ref nodes index).handle.index 1)))
      (set! index (+ index 1)))
    (let
      [table : (__tl_dyn-array i64) (__tl_make-array i64 limit)]
      (set! index 0)
      (while (< index limit)
        (set! (array-ref table index) -1)
        (set! index (+ index 1)))
      (set! index 0)
      (while (< index (array-length nodes))
        (when
          (>= (array-ref nodes index).handle.index 0)
          (set! (array-ref table (array-ref nodes index).handle.index) index))
        (set! index (+ index 1)))
      table)))

;; The root local of `node`'s operand `slot`, or -1.
(define (normalize-operand-local
  [body : (& body own.OwnershipBody)]
  [node : (& node NormalizeNode)]
  [slot : i64]) : i64
  (if (< slot (array-length node.operands))
    (normalize-place-local body (array-ref node.operands slot))
    -1))

(define (normalize-place-local
  [body : (& body own.OwnershipBody)]
  [place : i64]) : i64
  (if (and (>= place 0) (< place (array-length body.places)))
    (array-ref body.places place).local.index
    -1))

;; The root local of the binder with this handle, or -1.
(define (normalize-binder-local
  [output : (& output OwnershipNormalizedBody)]
  [handle : (& handle typed.TypedHandle)]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (while (and (< found 0) (< index (array-length output.binders)))
      (when
        (typed.typed-handle-equal?
          (& (array-ref output.binders index).handle)
          handle)
        (set!
          found
          (normalize-place-local
            (& output.body)
            (array-ref output.binders index).place)))
      (set! index (+ index 1)))
    found))

(define (normalize-class-find
  [classes : (&mut classes (__tl_dyn-array i64))]
  [local : i64]) : i64
  (let
    [at : i64 local]
    (while (!= (array-ref classes at) at)
      (set! (array-ref classes at) (array-ref classes (array-ref classes at)))
      (set! at (array-ref classes at)))
    at))

(define (normalize-class-union!
  [classes : (&mut classes (__tl_dyn-array i64))]
  [left : i64]
  [right : i64]) : unit
  (let
    [a : i64 (normalize-class-find classes left)]
    [b : i64 (normalize-class-find classes right)]
    (when (!= a b) (set! (array-ref classes a) b))))

;; A compiler built with `--cfg ownership-mir-dump` prints every normalized
;; body's ownership graph to stderr before the core checks it (a debugging
;; aid; other builds print nothing).
(define (normalize-mir-dump [body : (& body own.OwnershipBody)]) : unit
  (cfg
    ownership-mir-dump
    (match (ownership_dump.ownership-dump body (own.ownership-default-limits))
      [(ownership_dump.OwnershipDumpResult.Ok text) (io.print-error text)]
      [(ownership_dump.OwnershipDumpResult.Err _)
        (io.print-error "ownership-mir-dump: the graph does not validate\n")]))
  unit)

;; `products` gives the struct and tuple shapes by class key (see
;; `OwnershipNormalizeProduct`); a body without projections needs none.
(define (ownership-normalize-with-products!
  [store : (&mut store typed.TypedStore)]
  [lease : (& lease (typed.TypedBodyLease intern))]
  [root : typed.TypedOccurrenceId]
  [return-type : typed.TypedTypeId]
  [classes : (__tl_dyn-array OwnershipNormalizeTypeClass)]
  [products : (__tl_dyn-array OwnershipNormalizeProduct)]
  [variances : OwnershipNormalizeVariances]
  [writes : OwnershipNormalizeGlobalWrites]
  [limits : OwnershipNormalizeLimits]) : OwnershipNormalizeResult
  ;; A hard depth ceiling bounds compiler stack use even for caller-supplied
  ;; limits (the compiler runs on the runtime's 1 GiB main stack). All
  ;; arithmetic below is subtraction-checked before allocation.
  (unless
    (and
      (>= limits.records 32)
      (<= limits.records 1048576)
      (>= limits.depth 1)
      (<= limits.depth 4096)
      (>= limits.work 32)
      (>= limits.source-bytes 1))
    (return (OwnershipNormalizeResult.Err OwnershipNormalizeFailure.Resource)))
  (let
    [types : (__tl_dyn-array own.OwnershipType)
      (__tl_make-array own.OwnershipType 0)]
    [type : i64 0]
    ;; Primitive codes 0-12, then the Never slot 13, which never receives
    ;; storage (`normalize-storage-type?`).
    (while (< type normalize-first-value-type)
      (begin
        (__tl_array-push!
          types
          (own.OwnershipType
            (if (= type 1)
              own.OwnershipTypeKind.Boolean
              own.OwnershipTypeKind.Scalar)
            true))
        (set! type (+ type 1))))
    (let
      [state : NormalizeState
        (NormalizeState
          (own.OwnershipBody
            (typed.typed-body-copy (& lease.body))
            types
            (__tl_make-array own.OwnershipLocal 0)
            (__tl_make-array own.OwnershipPlace 0)
            (__tl_make-array own.OwnershipLoan 0)
            (__tl_make-array own.OwnershipCleanup 0)
            (__tl_make-array own.OwnershipObligation 0)
            (__tl_make-array own.OwnershipBlock 0)
            (own.OwnershipBlockId (typed.typed-body-copy (& lease.body)) 0))
          classes
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array bool 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          products
          variances
          writes
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array own.OwnershipSource 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array own.OwnershipSource 0)
          (__tl_make-array bool 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          -1
          -1
          false
          false
          false
          false
          (__tl_make-array typed.TypedBinderId 0)
          (__tl_make-array i64 0)
          (__tl_make-array bool 0)
          (__tl_make-array i64 0)
          0
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array own.OwnershipSource 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array bool 0)
          0
          false
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array NormalizeNode 0)
          (__tl_make-array NormalizeBinder 0)
          limits
          24
          24
          0
          -1
          -1
          -1
          0
          0
          (__tl_make-array i64 0)
          0
          (__tl_make-array i64 0)
          0
          0
          0
          0
          0
          0
          -1
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (normalize-i64s)
          (normalize-i64s)
          (normalize-i64s)
          (normalize-i64s)
          (normalize-i64s)
          (normalize-bools)
          (normalize-i64s)
          -1
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array bool 0)
          (__tl_make-array bool 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          0
          0
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array own.OwnershipSource 0)
          (__tl_make-array i64 0)
          -1
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array i64 0)
          (__tl_make-array NormalizeDeferredReceiver 0)
          0)]
      [_keys : unit
        (while (<
          (array-length state.type-keys)
          (array-length state.body.types))
          (__tl_array-push! state.type-keys -1))]
      [_projected : unit (try (normalize-projected! (&mut state) store lease))]
      [result-type : i64
        (try (normalize-type! (&mut state) store lease return-type))]
      [_result : unit (set! state.return-type result-type)]
      [_parameters : unit
        (try (normalize-parameters! (&mut state) store lease))]
      [entry : i64 (try (normalize-parameter-entry! (&mut state)))]
      [_globals : unit
        (try (normalize-global-places! (&mut state) store lease))]
      [value
        : NormalizeValue
        ;; The body's value is what it returns.
        (try
          (normalize-walk-in-context! (&mut state) store lease root entry 0 4))]
      [_issued : unit
        (when
          (normalize-deferred-pending? (& state))
          (return
            (OwnershipNormalizeResult.Err
              (OwnershipNormalizeFailure.Unsupported
                "ownership normalization: unissued referent loan"))))]
      (unless
        (or (= value.type 13) (= value.type result-type))
        (return (OwnershipNormalizeResult.Err (normalize-type-error))))
      (when
        (>= value.block 0)
        (let
          [operands : (__tl_dyn-array own.OwnershipPlaceId)
            (__tl_make-array own.OwnershipPlaceId 0)]
          ;; The function's own obligations (`:invalidate` brands)
          ;; end with its body.
          (when
            (> state.owner-count 0)
            (let
              [header : NormalizeHeader
                (try (normalize-header! (&mut state) store lease root))]
              [source : own.OwnershipSource
                (match (typed.typed-origin-get! store lease header.origin)
                  [(typed.TypedOriginView.Ok source)
                    (try (normalize-source-copy! (&mut state) source))]
                  [(typed.TypedOriginView.Err error)
                    (return
                      (OwnershipNormalizeResult.Err
                        (OwnershipNormalizeFailure.Typed error)))])]
              (try
                (normalize-exit-owners! (&mut state) value.block 0 5 (& source)))))
          (try (normalize-charge! (&mut state) 2 2 0))
          (normalize-i64s-push! (&mut state.return-places) value.place)
          (__tl_array-push! operands (normalize-place-id (& state) value.place))
          (try
            (normalize-terminate!
              (&mut state)
              value.block
              (own.OwnershipTerminator.Return (own.OwnershipPlaceIds operands))))))
      (try (normalize-note-exit-referent-uses! (&mut state)))
      (normalize-trim! (&mut state))
      (let
        [shapes : NormalizeShapes
          (match (normalize-compute-shapes!
            (& state)
            store
            lease
            return-type.handle.index)
            [(NormalizeShapesResult.Ok shapes) shapes]
            [(NormalizeShapesResult.Err failure)
              (return (OwnershipNormalizeResult.Err failure))])]
        (try (normalize-solve-origins! (&mut state) (& shapes))))
      (normalize-mir-dump (& state.body))
      (match (own.ownership-check (& state.body) state.limits.core)
        [(own.OwnershipResult.Ok)
          (let
            [_charged : unit
              (try
                (normalize-charge!
                  (&mut state)
                  0
                  (+
                    (normalize-deferred-work (& state))
                    (*
                      (array-length state.binders)
                      (array-length state.body.loans)))
                  0))]
            [deferred : OwnershipNormalizeDeferred
              (match (normalize-deferred-effects (& state) state.limits.core)
                [(NormalizeDeferredEffectsResult.Ok value) value]
                [(NormalizeDeferredEffectsResult.Err failure)
                  (return (OwnershipNormalizeResult.Err failure))])]
            [borrowed-globals : (__tl_dyn-array i64)
              (normalize-borrowed-globals (& state))]
            (OwnershipNormalizeResult.Ok
              (OwnershipNormalizedBody
                state.body
                state.nodes
                state.binders
                root
                result-type
                state.records
                state.work
                state.bytes
                deferred
                borrowed-globals)))]
        ;; The core's own bounds and unsupported shapes are this route's
        ;; limits, not the program's: such a body is unsupported here.
        [(own.OwnershipResult.Err failure)
          (OwnershipNormalizeResult.Err
            (match (normalize-core-limit (& failure))
              [(NormalizeCoreLimit.Resource)
                (return
                  (OwnershipNormalizeResult.Err
                    OwnershipNormalizeFailure.Resource))]
              [(NormalizeCoreLimit.Unsupported)
                (return
                  (OwnershipNormalizeResult.Err
                    (OwnershipNormalizeFailure.Unsupported
                      "ownership normalization: core unsupported shape")))]
              [(NormalizeCoreLimit.No)
                (match (normalize-obligation-diagnostic (& state) (& failure))
                  [(NormalizeObligationDiagnosticResult.Some diagnostic)
                    (return
                      (OwnershipNormalizeResult.Err
                        (OwnershipNormalizeFailure.Obligation diagnostic)))]
                  [(NormalizeObligationDiagnosticResult.No) unit])
                (match (normalize-move-diagnostic (& state) (& failure))
                  [(NormalizeMoveDiagnosticResult.Some diagnostic)
                    (OwnershipNormalizeFailure.Moved failure diagnostic)]
                  [(NormalizeMoveDiagnosticResult.No)
                    (match (normalize-borrow-diagnostic (& state) (& failure))
                      [(NormalizeBorrowDiagnosticResult.Some diagnostic)
                        (OwnershipNormalizeFailure.Borrowed failure diagnostic)]
                      [(NormalizeBorrowDiagnosticResult.No)
                        (OwnershipNormalizeFailure.Core failure)])])]))]))))