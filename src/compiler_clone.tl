;; compiler_clone.tl - synthesize clone$<Type> helpers.
;;
;; `(clone x)` is the canonical deep-copy and the canonical way to escape an
;; arena. The lowerer dispatches `(clone x)` to `clone$<type-of-x>` for named
;; aggregate types (enums/structs); strings copy their buffer via `substring`
;; and scalars are returned as-is. This module is a driver pre-pass: for every
;; clone-able enum/struct type in the program it generates a recursive
;; `clone$<Name>` define and prepends it, so a self-hosted compiler supports
;; `(clone x)` for any user type (mirroring the Rust generic clone codegen).
;;
;; tuple, fixed array, dynamic array, Box of a clone-able type, or another
;; clone-able named type. Function, reference, raw-pointer, str, and
;; compile-time-only values are not clone-able. Clone-ability is a
;; least-fixed-point over the type graph.
(import compiler_ast_types as ast)
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import stdlib.arena)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as clone_id_map)
(import stdlib.string)

(defstruct CloneNameSet
  (map clone_id_map.Map)
  (aliases clone_id_map.Map))

(defstruct CloneRootEntry
  ;; Nominal type key and the generated helper identity created for that key.
  (key-id i64)
  (helper-id i64))

;; Physical entries are oldest -> newest.  A view stores a physical prefix/range
;; and presents it newest -> oldest through clone-root-entries-* accessors.
;; The store is boxed so snapshots share the dense buffer while retaining their
;; own start/length pair across appends and geometric growth.
(defstruct CloneRootEntryStore
  (entries (__tl_dyn-array CloneRootEntry))
  (len i64)
  (key-index clone_id_map.Map)
  (arena i64))

(defenum CloneRootEntries
  (Empty)
  (Dense (Box CloneRootEntryStore) i64 i64))

(define (clone-helper-name-id-new-for-key [type-key-id : i64]) : i64
  (ci.intern-generated-canonical-name
    (clone-local-helper-name
      (ci.intern-str (clone-name-key-base-id type-key-id)))))

(define (clone-root-module-id) : i64
  -1)

(define (clone-module-id-root? [module-id : i64]) : bool
  (or (< module-id 0) (= (string.string-length (ci.intern-str module-id)) 0)))

;; Pair keys live above the intern-id range, so a root name id and a
;; module-qualified `(module-id, base-id)` cannot collide.
(define (clone-name-pair-key-id [module-id : i64] [base-id : i64]) : i64
  (ci.intern-composite-pair-id module-id base-id))

(define (clone-name-key-qualified? [key-id : i64]) : bool
  (ci.intern-composite-pair-id? key-id))

(define (clone-name-key-module-id [key-id : i64]) : i64
  (ci.intern-composite-left-id-unchecked key-id))

(define (clone-name-key-base-id [key-id : i64]) : i64
  (if (clone-name-key-qualified? key-id)
    (ci.intern-composite-right-id-unchecked key-id)
    key-id))

;; Preserve the old canonicalization rules without allocating or interning a
;; joined `module/name` string. Slash-qualified source ids already carry their
;; module/base ids in the interner metadata; dotted names remain atomic.
(define (clone-name-key-id-in-module [module-id : i64] [name-id : i64]) : i64
  (cond
    [(or
        (ci.intern-composite-pair-id? name-id)
        (ci.intern-composite-triple-id? name-id)
        (ci.intern-macro-global-structural-id? name-id))
      name-id]
    [(and (ci.intern-renderable-id? name-id) (ci.intern-qualified? name-id))
      (clone-name-pair-key-id
        (ci.intern-qualified-module-id name-id)
        (ci.intern-qualified-base-id name-id))]
    [(or
        (clone-module-id-root? module-id)
        (and (ci.intern-renderable-id? name-id) (ci.intern-dotted? name-id)))
      name-id]
    [else (clone-name-pair-key-id module-id name-id)]))

(define (clone-name-key-id [name-id : i64]) : i64
  (clone-name-key-id-in-module (clone-root-module-id) name-id))

(define (clone-name-key-string [key-id : i64]) : String
  (if (clone-name-key-qualified? key-id)
    (string.append
      (ci.intern-str (clone-name-key-module-id key-id))
      (string.append "/" (ci.intern-str (clone-name-key-base-id key-id))))
    (if (ci.intern-renderable-id? key-id)
      (ci.intern-str key-id)
      "<structural-name>")))

(define (clone-type-name-last-slash [name : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [last : i64 -1]
    (begin
      (while (< i n)
        (begin
          (if (= (cast (string.string-ref name i) : i64) (cast '/' : i64))
            (set! last i)
            unit)
          (set! i (+ i 1))))
      last)))

(define (clone-type-name-module [name : String]) : String
  (let
    [last : i64 (clone-type-name-last-slash name)]
    (if (< last 0)
      ""
      (string.substring name 0 last))))

(define (clone-type-name-base [name : String]) : String
  (let
    [last : i64 (clone-type-name-last-slash name)]
    [n : i64 (string.string-length name)]
    (if (< last 0)
      name
      (string.substring name (+ last 1) (- n (+ last 1))))))

(define (clone-import-alias-key-id [module-id : i64] [alias-id : i64]) : i64
  (clone-name-key-id-in-module module-id alias-id))

(define (clone-type-name-resolve-id
  [names : CloneNameSet]
  [module-id : i64]
  [name-id : i64]) : i64
  (if (and (ci.intern-renderable-id? name-id) (ci.intern-dotted? name-id))
    (let
      [aliases : clone_id_map.Map (struct-get names aliases)]
      [alias-id : i64 (ci.intern-leading-dot-id name-id)]
      [key-id : i64 (clone-import-alias-key-id module-id alias-id)]
      (match (clone_id_map.get (& aliases) key-id)
        [(clone_id_map.LookupFound target-module-id)
          (clone-name-pair-key-id
            target-module-id
            (ci.intern-dotted-tail-id name-id))]
        [(clone_id_map.LookupMissing)
          (clone-name-key-id-in-module module-id name-id)]))
    (clone-name-key-id-in-module module-id name-id)))

(define (clone-local-helper-name [type-name : String]) : String
  (string.append "clone$" (clone-type-name-base type-name)))

(define (clone-helper-name [type-name : String]) : String
  (let
    [module : String (clone-type-name-module type-name)]
    [local : String (clone-local-helper-name type-name)]
    (if (string.eq module "")
      local
      (string.append (string.append module "/") local))))

(define (clone-name-set-empty) : CloneNameSet
  (CloneNameSet (clone_id_map.with-capacity 8) (clone_id_map.with-capacity 8)))

(define (clone-name-set-for-decls [decls : ast.AstDeclList]) : CloneNameSet
  (let
    [aliases : clone_id_map.Map (clone_id_map.with-capacity 64)]
    [current-module-id : i64 (clone-root-module-id)]
    [index : i64 0]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    (begin
      (while (< index count)
        (begin
          ;; Borrowed classification first: only module markers and imports
          ;; carry a payload this alias table reads.
          (if (ast.ast-decl-list-unwrapped-module-or-import-at? (& decls) index)
            (match (ast.ast-decl-unwrapped
              (ast.ast-decl-list-get (& decls) index (ast.ast-decl-fallback)))
              [(ast.AstDecl.Module next-module)
                (set! current-module-id next-module)]
              [(ast.AstDecl.Import
                  decl-meta
                  (ast.AstImportSpec.Spec
                    _
                    _
                    (ast.AstMaybeModuleName.Some target)
                    (ast.AstMaybeImportAlias.Some alias)
                    _))
                (clone_id_map.insert-ref!
                  (&mut aliases)
                  (clone-import-alias-key-id current-module-id alias)
                  target)]
              [_ unit])
            unit)
          (set! index (+ index 1))))
      (CloneNameSet (clone_id_map.with-capacity 8) aliases))))

;; The fixpoint rebuilds its accepted set on each step over the whole-program
;; type universe; seeding that accumulator at the input set's capacity (it can
;; only shrink relative to the input) avoids the rehash+fill-empty grow chain a
;; capacity-8 seed would walk on every step.
(define (clone-name-set-with-capacity
  [capacity : i64]
  [aliases : clone_id_map.Map]) : CloneNameSet
  (CloneNameSet (clone_id_map.with-capacity capacity) aliases))

(define (clone-name-set-map [names : CloneNameSet]) : clone_id_map.Map
  (struct-get names map))

(define (clone-name-set-aliases [names : CloneNameSet]) : clone_id_map.Map
  (struct-get names aliases))

(define (clone-name-set-insert-alias-id
  [names : CloneNameSet]
  [module-id : i64]
  [alias-id : i64]
  [target-module-id : i64]) : CloneNameSet
  (let
    [aliases : clone_id_map.Map (clone-name-set-aliases names)]
    (begin
      (clone_id_map.insert-ref!
        (&mut aliases)
        (clone-import-alias-key-id module-id alias-id)
        target-module-id)
      (CloneNameSet (clone-name-set-map names) aliases))))

(define (clone-name-set-insert-id [names : CloneNameSet] [key-id : i64]) : CloneNameSet
  (let
    [map (clone-name-set-map names)]
    (begin
      (if (>= key-id 0)
        (clone_id_map.insert-ref! (&mut map) key-id 1)
        unit)
      (CloneNameSet map (clone-name-set-aliases names)))))

(define (clone-name-set-contains-id? [names : CloneNameSet] [key-id : i64]) : bool
  (let
    [map (clone-name-set-map names)]
    (if (< key-id 0)
      false
      (clone_id_map.contains? (& map) key-id))))

(define (clone-name-set-contains-canonical-id?
  [names : CloneNameSet]
  [module-id : i64]
  [name-id : i64]) : bool
  (clone-name-set-contains-id?
    names
    (clone-name-key-id-in-module module-id name-id)))

;; A bare nominal spelled inside a module can still be the enclosing program's
;; root-module type: generated families (`stdlib.vector`, `stdlib.hashmap`, ...)
;; splice their element type's unqualified name into declarations that live in
;; their own namespace. Only unqualified, undotted, interned names seen from a
;; non-root module may fall back to the root key.
(define (clone-name-root-fallback-eligible? [module-id : i64] [name-id : i64]) : bool
  (not
    (or
      (clone-module-id-root? module-id)
      (not (ci.intern-renderable-id? name-id))
      (and (>= name-id 0) (ci.intern-qualified? name-id))
      (and (>= name-id 0) (ci.intern-dotted? name-id)))))

(define (clone-name-set-contains-resolved-nominal-id?
  [names : CloneNameSet]
  [module-id : i64]
  [name-id : i64]) : bool
  (if (clone-name-set-contains-id?
    names
    (clone-type-name-resolve-id names module-id name-id))
    true
    (if (clone-name-root-fallback-eligible? module-id name-id)
      (clone-name-set-contains-id? names (clone-name-key-id name-id))
      false)))

;; Resolve a nominal to the key the clone-able set actually accepted it under.
;; The root walk has to agree with `clone-name-set-contains-resolved-nominal-id?`
;; here: a generated module names its element type unqualified inside its own
;; namespace, so the module-qualified key misses and the declaring root key is
;; the one that carries the helper. Without this the element type is admitted as
;; clone-able but never collected as a root, and lowering the generated helper's
;; element clone fails with `missing generated clone helper for <Element>`.
(define (clone-root-nominal-key-id
  [able : CloneNameSet]
  [module-id : i64]
  [name-id : i64]) : i64
  (let
    [resolved : i64 (clone-type-name-resolve-id able module-id name-id)]
    (if (clone-name-set-contains-id? able resolved)
      resolved
      (if (clone-name-root-fallback-eligible? module-id name-id)
        (let
          [root-key : i64 (clone-name-key-id name-id)]
          (if (clone-name-set-contains-id? able root-key)
            root-key
            resolved))
        resolved))))

;; Arena ownership follows the persistent store pattern used by lower-name
;; stores and typechecker environments.  The owner root/current head is used
;; for every store allocation; an unrelated caller arena is restored after the
;; operation, while a caller already in this owner keeps its advanced head.
(define (clone-root-entries-arena-owner-root [handle : i64]) : i64
  (if (= handle 0)
    0
    (let
      [root : i64
        (unsafe
          (ptr-read (ptr-offset (int->ptr handle : (Ptr i64)) 5)))]
      (if (= root 0)
        handle
        root))))

(define (clone-root-entries-arena-owner-current-head [handle : i64]) : i64
  (let
    [root : i64 (clone-root-entries-arena-owner-root handle)]
    (if (= root 0)
      0
      (let
        [head : i64
          (unsafe
            (ptr-read (ptr-offset (int->ptr root : (Ptr i64)) 7)))]
        (if (= head 0)
          root
          head)))))

(define (clone-root-entries-arena-restore-after-owner-alloc!
  [previous-arena : i64]
  [owner : i64]) : unit
  (if (=
    (clone-root-entries-arena-owner-root previous-arena)
    (clone-root-entries-arena-owner-root owner))
    unit
    (unsafe
      (arena.tl_arena_set
        (clone-root-entries-arena-owner-current-head previous-arena)))))

(define (clone-root-entries-empty) : CloneRootEntries
  CloneRootEntries.Empty)

(define (clone-root-entries-empty? [roots : CloneRootEntries]) : bool
  (match roots
    [(CloneRootEntries.Empty) true]
    [_ false]))

(define (clone-root-entries-len [roots : CloneRootEntries]) : i64
  (match roots
    [(CloneRootEntries.Empty) 0]
    [(CloneRootEntries.Dense _ _ len) len]))

(define (clone-root-entries-capacity [roots : CloneRootEntries]) : i64
  (match roots
    [(CloneRootEntries.Empty) 0]
    [(CloneRootEntries.Dense store _ _)
      (array-length (struct-get (box-get store) entries))]))

(define (clone-root-entries-physical-len [roots : CloneRootEntries]) : i64
  (match roots
    [(CloneRootEntries.Empty) 0]
    [(CloneRootEntries.Dense store _ _) (struct-get (box-get store) len)]))

(define (clone-root-entries-store-new) : (Box CloneRootEntryStore)
  (let
    [owner : i64 (clone-root-entries-arena-owner-root (arena.tl_arena_current))]
    (box
      (CloneRootEntryStore
        (make-array CloneRootEntry 4)
        0
        (clone_id_map.with-capacity 8)
        owner))))

(define (clone-root-entries-store-copy-range!
  [dst : (&mut dst (__tl_dyn-array CloneRootEntry))]
  [src : (& src (__tl_dyn-array CloneRootEntry))]
  [index : i64]
  [count : i64]) : unit
  (let
    [cursor : i64 index]
    (begin
      (while (< cursor count)
        (begin
          (array-set! dst cursor (array-ref src cursor))
          (set! cursor (+ cursor 1))))
      unit)))

(define (clone-root-entries-store-grow!
  [store : (&mut store CloneRootEntryStore)]) : unit
  (let
    [owner : i64 (struct-get store arena)]
    [previous-arena : i64 (arena.tl_arena_current)]
    [old-capacity : i64 (array-length (struct-get store entries))]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    (begin
      (unsafe
        (arena.tl_arena_set (clone-root-entries-arena-owner-current-head owner)))
      (let
        [bigger : (__tl_dyn-array CloneRootEntry)
          (make-array CloneRootEntry new-capacity)]
        (begin
          ;; Only the live physical prefix is copied; snapshots share the new
          ;; dense handle and retain their old start/length bounds.
          (clone-root-entries-store-copy-range!
            (&mut bigger)
            (& (struct-get store entries))
            0
            (struct-get store len))
          (set! (struct-get store entries) bigger)))
      (clone-root-entries-arena-restore-after-owner-alloc! previous-arena owner))))

(define (clone-root-entries-store-entry-at
  [store : (& store CloneRootEntryStore)]
  [index : i64]) : CloneRootEntry
  (unsafe
    (ptr-read (ptr-offset (array-data (struct-get store entries)) index))))

(define (clone-root-entries-entry-at-or
  [roots : CloneRootEntries]
  [logical-index : i64]
  [fallback : CloneRootEntry]) : CloneRootEntry
  (match roots
    [(CloneRootEntries.Empty) fallback]
    [(CloneRootEntries.Dense store start len)
      (if (and (>= logical-index 0) (< logical-index len))
        (let
          [physical : i64 (+ start (- len (+ logical-index 1)))]
          (clone-root-entries-store-entry-at (& (box-get store)) physical))
        fallback)]))

(define (clone-root-entries-key-id-at-or
  [roots : CloneRootEntries]
  [logical-index : i64]
  [fallback : i64]) : i64
  (struct-get
    (clone-root-entries-entry-at-or
      roots
      logical-index
      (CloneRootEntry fallback fallback))
    key-id))

(define (clone-root-entries-helper-id-at-or
  [roots : CloneRootEntries]
  [logical-index : i64]
  [fallback : i64]) : i64
  (struct-get
    (clone-root-entries-entry-at-or
      roots
      logical-index
      (CloneRootEntry fallback fallback))
    helper-id))

(define (clone-root-entries-store-index-in-view-or
  [store : (& store CloneRootEntryStore)]
  [start : i64]
  [len : i64]
  [key-id : i64]) : i64
  (if (< key-id 0)
    -1
    (match (clone_id_map.get (& (struct-get store key-index)) key-id)
      [(clone_id_map.LookupFound physical)
        (if (and (>= physical start) (< physical (+ start len)))
          physical
          -1)]
      [(clone_id_map.LookupMissing) -1])))

(define (clone-root-entries-contains-id?
  [roots : CloneRootEntries]
  [key-id : i64]) : bool
  (match roots
    [(CloneRootEntries.Empty) false]
    [(CloneRootEntries.Dense store start len)
      (>=
        (clone-root-entries-store-index-in-view-or
          (& (box-get store))
          start
          len
          key-id)
        0)]))

(define (clone-root-entries-helper-id-or
  [roots : CloneRootEntries]
  [key-id : i64]
  [fallback : i64]) : i64
  (match roots
    [(CloneRootEntries.Empty) fallback]
    [(CloneRootEntries.Dense store start len)
      (let
        [physical : i64
          (clone-root-entries-store-index-in-view-or
            (& (box-get store))
            start
            len
            key-id)]
        (if (< physical 0)
          fallback
          (struct-get
            (clone-root-entries-store-entry-at (& (box-get store)) physical)
            helper-id)))]))

;; Recover an imported nominal's canonical key when a generated declaration
;; retains only its unqualified base name. Ambiguous bases deliberately fail:
;; the lowerer must never bind a clone call to the wrong module's helper.
(define (clone-root-entries-unique-key-for-base-id-or
  [roots : CloneRootEntries]
  [base-id : i64]
  [fallback : i64]) : i64
  (let
    [index : i64 0]
    [result : i64 fallback]
    [found : bool false]
    [ambiguous : bool false]
    [count : i64 (clone-root-entries-len roots)]
    (begin
      (while (and (< index count) (not ambiguous))
        (let
          [key-id : i64 (clone-root-entries-key-id-at-or roots index -1)]
          (if (= (clone-name-key-base-id key-id) base-id)
            (if found
              (set! ambiguous true)
              (begin
                (set! result key-id)
                (set! found true)))
            unit)
          (set! index (+ index 1))))
      (if ambiguous
        fallback
        result))))

(define (clone-root-entries-materialize [roots : CloneRootEntries]) : CloneRootEntries
  (match roots
    [(CloneRootEntries.Empty) CloneRootEntries.Empty]
    [(CloneRootEntries.Dense _ _ len)
      (let
        [out-store : (Box CloneRootEntryStore) (clone-root-entries-store-new)]
        [index : i64 (- len 1)]
        (begin
          ;; Iterate physical oldest -> newest so helper identity and map first
          ;; indices are byte-for-byte preserved.
          (while (>= index 0)
            (let
              [entry : CloneRootEntry
                (clone-root-entries-entry-at-or
                  roots
                  index
                  (CloneRootEntry -1 -1))]
              ;; index is logical; physical materialization is easiest by
              ;; writing in reverse logical order to physical 0..len-1.
              (if (<
                (struct-get (box-get out-store) len)
                (array-length (struct-get (box-get out-store) entries)))
                unit
                (clone-root-entries-store-grow! (&mut (box-get out-store))))
              (let
                [physical : i64 (struct-get (box-get out-store) len)]
                (array-set!
                  (struct-get (box-get out-store) entries)
                  physical
                  entry)
                (set! (struct-get (box-get out-store) len) (+ physical 1))
                (let
                  [key-id : i64 (struct-get entry key-id)]
                  [map (struct-get (box-get out-store) key-index)]
                  (if (not (clone_id_map.contains? (& map) key-id))
                    (clone_id_map.insert-ref! (&mut map) key-id physical)
                    unit)
                  (set! (struct-get (box-get out-store) key-index) map))))
            (set! index (- index 1)))
          (CloneRootEntries.Dense out-store 0 len)))]))

(define (clone-root-entries-copy [roots : CloneRootEntries]) : CloneRootEntries
  (clone-root-entries-materialize roots))

(define (clone-root-entries-add-id [roots : CloneRootEntries] [key-id : i64]) : CloneRootEntries
  (if (or (< key-id 0) (clone-root-entries-contains-id? roots key-id))
    roots
    (let
      [helper-id : i64 (clone-helper-name-id-new-for-key key-id)]
      (match roots
        [(CloneRootEntries.Empty)
          (let
            [store : (Box CloneRootEntryStore) (clone-root-entries-store-new)]
            (begin
              (array-set!
                (struct-get (box-get store) entries)
                0
                (CloneRootEntry key-id helper-id))
              (set! (struct-get (box-get store) len) 1)
              (clone_id_map.insert-ref!
                (&mut (struct-get (box-get store) key-index))
                key-id
                0)
              (CloneRootEntries.Dense store 0 1)))]
        [(CloneRootEntries.Dense store start len)
          (let
            [store-len : i64 (struct-get (box-get store) len)]
            [tail? : bool (and (= start 0) (= len store-len))]
            [target : CloneRootEntries
              (if tail?
                roots
                (clone-root-entries-materialize roots))]
            (match target
              [(CloneRootEntries.Dense target-store target-start target-len)
                (let
                  [owner : i64 (struct-get (box-get target-store) arena)]
                  [previous-arena : i64 (arena.tl_arena_current)]
                  (begin
                    (unsafe
                      (arena.tl_arena_set
                        (clone-root-entries-arena-owner-current-head owner)))
                    (if (>=
                      (struct-get (box-get target-store) len)
                      (array-length (struct-get (box-get target-store) entries)))
                      (clone-root-entries-store-grow!
                        (&mut (box-get target-store)))
                      unit)
                    (let
                      [physical : i64 (struct-get (box-get target-store) len)]
                      (array-set!
                        (struct-get (box-get target-store) entries)
                        physical
                        (CloneRootEntry key-id helper-id))
                      (set!
                        (struct-get (box-get target-store) len)
                        (+ physical 1))
                      (clone_id_map.insert-ref!
                        (&mut (struct-get (box-get target-store) key-index))
                        key-id
                        physical)
                      (clone-root-entries-arena-restore-after-owner-alloc!
                        previous-arena
                        owner)
                      (CloneRootEntries.Dense
                        target-store
                        target-start
                        (+ target-len 1)))))]
              [_ target]))]))))

(define (clone-root-entries-take [roots : CloneRootEntries] [count : i64]) : CloneRootEntries
  (if (<= count 0)
    CloneRootEntries.Empty
    (let
      [len : i64 (clone-root-entries-len roots)]
      (if (>= count len)
        roots
        (match roots
          [(CloneRootEntries.Empty) CloneRootEntries.Empty]
          [(CloneRootEntries.Dense store start _)
            (CloneRootEntries.Dense store (+ start (- len count)) count)])))))

(define (clone-root-entries-drop [roots : CloneRootEntries] [count : i64]) : CloneRootEntries
  (if (<= count 0)
    roots
    (let
      [len : i64 (clone-root-entries-len roots)]
      (if (>= count len)
        CloneRootEntries.Empty
        (match roots
          [(CloneRootEntries.Empty) CloneRootEntries.Empty]
          [(CloneRootEntries.Dense store start _)
            (CloneRootEntries.Dense store start (- len count))])))))

(define (clone-name-set-len [names : CloneNameSet]) : i64
  (let
    [map (clone-name-set-map names)]
    (clone_id_map.len (& map))))

(define (clone-name-set-capacity [names : CloneNameSet]) : i64
  (let
    [map (clone-name-set-map names)]
    (clone_id_map.capacity (& map))))

(define (clone-name-set-smoke-insert-count [names : CloneNameSet] [count : i64]) : CloneNameSet
  (if (<= count 0)
    names
    (clone-name-set-smoke-insert-count
      (clone-name-set-insert-id names (+ count 10))
      (- count 1))))

(define (clone-name-set-smoke-ok?) : bool
  (let
    [empty : CloneNameSet (clone-name-set-empty)]
    [one : CloneNameSet (clone-name-set-insert-id empty 1)]
    [dupe : CloneNameSet (clone-name-set-insert-id one 1)]
    [seed-capacity : i64 (clone-name-set-capacity dupe)]
    [grown : CloneNameSet (clone-name-set-smoke-insert-count dupe 10)]
    [base-id : i64 (ci.intern "CloneSmokeKey")]
    [first-key : i64
      (clone-name-pair-key-id (ci.intern "clone.smoke.first") base-id)]
    [second-key : i64
      (clone-name-pair-key-id (ci.intern "clone.smoke.second") base-id)]
    [unique : CloneRootEntries
      (clone-root-entries-add-id (clone-root-entries-empty) first-key)]
    [ambiguous : CloneRootEntries (clone-root-entries-add-id unique second-key)]
    (and
      (not (clone-name-set-contains-id? one 2))
      (clone-name-set-contains-id? one 1)
      (= (clone-name-set-len dupe) 1)
      (= (clone-name-set-len grown) 11)
      (=
        (clone-root-entries-unique-key-for-base-id-or unique base-id -1)
        first-key)
      (= (clone-root-entries-unique-key-for-base-id-or ambiguous base-id -1) -1)
      (> (clone-name-set-capacity grown) seed-capacity))))

(define (clone-root-entries-smoke-key-id [index : i64]) : i64
  (ci.intern (string.append "CloneDenseSmokeRoot" (string.int->string index))))

(define (clone-root-entries-smoke-add-sequential
  [roots : CloneRootEntries]
  [start : i64]
  [end : i64]) : CloneRootEntries
  (let
    [out : CloneRootEntries roots]
    [index : i64 start]
    (begin
      (while (< index end)
        (begin
          (set!
            out
            (clone-root-entries-add-id
              out
              (clone-root-entries-smoke-key-id index)))
          (set! index (+ index 1))))
      out)))

(define (clone-root-entries-smoke-order-ok? [roots : CloneRootEntries]) : bool
  (let
    [index : i64 0]
    [count : i64 (clone-root-entries-len roots)]
    [ok : bool true]
    (begin
      (while (and (< index count) ok)
        (if (not
          (=
            (clone-root-entries-key-id-at-or roots index -1)
            (clone-root-entries-smoke-key-id (- count (+ index 1)))))
          (set! ok false)
          unit)
        (set! index (+ index 1)))
      ok)))

(define (clone-root-entries-smoke-copy-equal?
  [left : CloneRootEntries]
  [right : CloneRootEntries]) : bool
  (let
    [index : i64 0]
    [count : i64 (clone-root-entries-len left)]
    [ok : bool (= count (clone-root-entries-len right))]
    (begin
      (while (and (< index count) ok)
        (if (and
          (=
            (clone-root-entries-key-id-at-or left index -1)
            (clone-root-entries-key-id-at-or right index -1))
          (=
            (clone-root-entries-helper-id-at-or left index -1)
            (clone-root-entries-helper-id-at-or right index -1)))
          unit
          (set! ok false))
        (set! index (+ index 1)))
      ok)))

(define (clone-root-entries-smoke-ok?) : bool
  (let
    [empty : CloneRootEntries (clone-root-entries-empty)]
    [first-key : i64 (clone-root-entries-smoke-key-id 0)]
    [grown-key : i64 (ci.intern "CloneDenseSmokeGrown")]
    [branch-key : i64 (ci.intern "CloneDenseSmokeBranch")]
    [first : CloneRootEntries (clone-root-entries-add-id empty first-key)]
    [duplicate : CloneRootEntries (clone-root-entries-add-id first first-key)]
    [roots : CloneRootEntries
      (clone-root-entries-smoke-add-sequential first 1 24)]
    [prefix : CloneRootEntries (clone-root-entries-take roots 3)]
    [first-helper : i64 (clone-root-entries-helper-id-or first first-key -1)]
    [prefix-helper : i64 (clone-root-entries-helper-id-at-or prefix 0 -1)]
    [grown : CloneRootEntries (clone-root-entries-add-id roots grown-key)]
    [branch : CloneRootEntries (clone-root-entries-add-id prefix branch-key)]
    [copy : CloneRootEntries (clone-root-entries-copy branch)]
    [base-id : i64 (ci.intern "CloneDenseSmokeKey")]
    [first-qualified : i64
      (clone-name-pair-key-id (ci.intern "clone.dense.first") base-id)]
    [second-qualified : i64
      (clone-name-pair-key-id (ci.intern "clone.dense.second") base-id)]
    [unique-base : i64 (ci.intern "CloneDenseUniqueKey")]
    [unique-qualified : i64
      (clone-name-pair-key-id (ci.intern "clone.dense.unique") unique-base)]
    [qualified : CloneRootEntries
      (clone-root-entries-add-id
        (clone-root-entries-add-id empty first-qualified)
        second-qualified)]
    [unique-root : CloneRootEntries
      (clone-root-entries-add-id empty unique-qualified)]
    (and
      ;; Empty is allocation-free and duplicate insertion is idempotent.
      (clone-root-entries-empty? empty)
      (= (clone-root-entries-physical-len empty) 0)
      (= (clone-root-entries-capacity empty) 0)
      (= (clone-root-entries-len duplicate) 1)
      (= (clone-root-entries-helper-id-or duplicate first-key -1) first-helper)
      ;; 24 entries cross three geometric growth boundaries and remain ordered.
      (= (clone-root-entries-len roots) 24)
      (clone-root-entries-smoke-order-ok? roots)
      ;; The one-entry snapshot remains unchanged after 4->8->16->32 growth,
      ;; while its shared physical store and map observe later entries.
      (= (clone-root-entries-len first) 1)
      (= (clone-root-entries-key-id-at-or first 0 -1) first-key)
      (= (clone-root-entries-helper-id-or first first-key -1) first-helper)
      (not (clone-root-entries-contains-id? first grown-key))
      (= (clone-root-entries-helper-id-or first grown-key -1) -1)
      (= (clone-root-entries-physical-len first) 25)
      (>= (clone-root-entries-capacity first) 25)
      (= (clone-root-entries-len roots) 24)
      (= (clone-root-entries-physical-len roots) 25)
      (>= (clone-root-entries-capacity roots) 25)
      (< (clone-root-entries-capacity roots) 50)
      ;; A recent slice remains separate from the divergent COW branch.
      (= (clone-root-entries-len prefix) 3)
      (= (clone-root-entries-helper-id-at-or prefix 0 -1) prefix-helper)
      (=
        (clone-root-entries-key-id-at-or prefix 0 -1)
        (clone-root-entries-smoke-key-id 23))
      (not (clone-root-entries-contains-id? prefix grown-key))
      (= (clone-root-entries-helper-id-or prefix grown-key -1) -1)
      (= (clone-root-entries-key-id-at-or grown 0 -1) grown-key)
      (= (clone-root-entries-len grown) 25)
      ;; Divergent append materializes the stale prefix, leaving the original
      ;; descendant untouched.
      (= (clone-root-entries-len branch) 4)
      (= (clone-root-entries-physical-len branch) 4)
      (>= (clone-root-entries-capacity branch) 4)
      (< (clone-root-entries-capacity branch) 8)
      (= (clone-root-entries-key-id-at-or branch 0 -1) branch-key)
      (=
        (clone-root-entries-key-id-at-or roots 0 -1)
        (clone-root-entries-smoke-key-id 23))
      (= (clone-root-entries-len copy) 4)
      (= (clone-root-entries-physical-len copy) 4)
      (>= (clone-root-entries-capacity copy) 4)
      (< (clone-root-entries-capacity copy) 8)
      (clone-root-entries-smoke-copy-equal? branch copy)
      (= (clone-root-entries-len (clone-root-entries-take roots 5)) 5)
      (= (clone-root-entries-len (clone-root-entries-drop roots 5)) 19)
      (=
        (clone-root-entries-key-id-at-or (clone-root-entries-drop roots 5) 0 -1)
        (clone-root-entries-smoke-key-id 18))
      ;; Qualified keys with one base stay ambiguous; a unique base resolves.
      (= (clone-root-entries-unique-key-for-base-id-or qualified base-id -1) -1)
      (=
        (clone-root-entries-unique-key-for-base-id-or
          unique-root
          unique-base
          -1)
        unique-qualified))))

(define (clone-type-get [pools : ast.AstNodePoolContext] [id : i64]) : ast.AstType
  (ast.ast-node-pool-context-type-get pools id))

;; A field type is clone-able given the current clone-able-name set: scalars,
;; String, tuples, fixed arrays, and dynamic arrays are clone-able recursively; a
;; named type (parsed as AstType.Var, or resolved to AstType.Enum/AstType.Struct) is
;; clone-able iff it is in `names`; everything else is not.
(define (clone-field-type-able-id?
  [pools : ast.AstNodePoolContext]
  [ty : ast.AstType]
  [names : CloneNameSet]
  [module-id : i64]) : bool
  (match ty
    [(ast.AstType.I64) true]
    [(ast.AstType.I32) true]
    [(ast.AstType.I16) true]
    [(ast.AstType.I8) true]
    [(ast.AstType.U64) true]
    [(ast.AstType.U32) true]
    [(ast.AstType.U16) true]
    [(ast.AstType.U8) true]
    [(ast.AstType.F64) true]
    [(ast.AstType.F32) true]
    [(ast.AstType.Bool) true]
    [(ast.AstType.Char) true]
    [(ast.AstType.Unit) true]
    [(ast.AstType.Never) true]
    [(ast.AstType.String) true]
    [(ast.AstType.Tuple elems)
      (clone-field-type-list-able? pools (box-get elems) names module-id)]
    [(ast.AstType.Array elem _)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools elem)
        names
        module-id)]
    [(ast.AstType.DynArray elem)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools elem)
        names
        module-id)]
    [(ast.AstType.Slice elem)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools elem)
        names
        module-id)]
    [(ast.AstType.Box elem)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools elem)
        names
        module-id)]
    [(ast.AstType.Region _ inner)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools inner)
        names
        module-id)]
    [(ast.AstType.Var name)
      (clone-name-set-contains-id?
        names
        (clone-type-name-resolve-id names module-id name))]
    [(ast.AstType.Enum name)
      (clone-name-set-contains-resolved-nominal-id? names module-id name)]
    [(ast.AstType.Struct name)
      (clone-name-set-contains-resolved-nominal-id? names module-id name)]
    [_ false]))

(define (clone-field-type-list-able?
  [pools : ast.AstNodePoolContext]
  [types : ast.AstTypeList]
  [names : CloneNameSet]
  [module-id : i64]) : bool
  (clone-field-type-list-able-at pools (& types) names module-id 0))

(define (clone-field-type-list-able-at
  [pools : ast.AstNodePoolContext]
  [types : (& types ast.AstTypeList)]
  [names : CloneNameSet]
  [module-id : i64]
  [index : i64]) : bool
  (if (>= index (ast.ast-type-list-len types))
    true
    (if (clone-field-type-able-id?
      pools
      (clone-type-get
        pools
        (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))
      names
      module-id)
      (clone-field-type-list-able-at pools types names module-id (+ index 1))
      false)))

(define (clone-variant-list-able?
  [pools : ast.AstNodePoolContext]
  [variants : ast.AstVariantDefList]
  [names : CloneNameSet]
  [module-id : i64]) : bool
  (clone-variant-list-able-at pools (& variants) names module-id 0))

(define (clone-variant-list-able-at
  [pools : ast.AstNodePoolContext]
  [variants : (& variants ast.AstVariantDefList)]
  [names : CloneNameSet]
  [module-id : i64]
  [index : i64]) : bool
  (if (>= index (ast.ast-variant-def-list-len variants))
    true
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def _ field-types _)
        (if (clone-field-type-list-able? pools field-types names module-id)
          (clone-variant-list-able-at
            pools
            variants
            names
            module-id
            (+ index 1))
          false)])))

(define (clone-struct-fields-able?
  [pools : ast.AstNodePoolContext]
  [fields : ast.AstFieldDefList]
  [names : CloneNameSet]
  [module-id : i64]) : bool
  (clone-struct-fields-able-at pools (& fields) names module-id 0))

(define (clone-struct-fields-able-at
  [pools : ast.AstNodePoolContext]
  [fields : (& fields ast.AstFieldDefList)]
  [names : CloneNameSet]
  [module-id : i64]
  [index : i64]) : bool
  (if (>= index (ast.ast-field-def-list-len fields))
    true
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def _ ty _)
        (if (clone-field-type-able-id? pools ty names module-id)
          (clone-struct-fields-able-at pools fields names module-id (+ index 1))
          false)])))

;; One fixpoint step: keep only names whose declaration's fields are all
;; clone-able under the current `names` set. Repeats until the set stops
;; shrinking (monotone decreasing, so it terminates).
(define (clone-fixpoint-step-in-module
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [names : CloneNameSet]
  [acc : CloneNameSet]
  [module-id : i64]) : CloneNameSet
  (let
    [out : CloneNameSet acc]
    [current-module-id : i64 module-id]
    [index : i64 0]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 (struct-get decls offset)]
    (begin
      (while (< index count)
        (begin
          ;; Classify through a borrow first: only module markers and the two
          ;; type-definition kinds have a payload this fixpoint reads, so every
          ;; other declaration is skipped without materialising a 104 B row and
          ;; copying it twice more through `ast-decl-unwrapped`.
          (if (ast.ast-decl-list-unwrapped-module-or-type-definition-at?
            (& decls)
            index)
            (match (ast.ast-decl-unwrapped
              (array-ref (struct-get decls slots) (+ decl-offset index)))
              [(ast.AstDecl.Module next-module)
                (set! current-module-id next-module)]
              [(ast.AstDecl.DefEnum decl-meta name _ variants)
                (if (clone-variant-list-able?
                  pools
                  variants
                  names
                  current-module-id)
                  (set!
                    out
                    (clone-name-set-insert-id
                      out
                      (clone-name-key-id-in-module current-module-id name)))
                  unit)]
              [(ast.AstDecl.DefStruct decl-meta name _ _ fields)
                (if (clone-struct-fields-able?
                  pools
                  fields
                  names
                  current-module-id)
                  (set!
                    out
                    (clone-name-set-insert-id
                      out
                      (clone-name-key-id-in-module current-module-id name)))
                  unit)]
              [_ unit])
            unit)
          (set! index (+ index 1))))
      out)))

(define (clone-fixpoint-step
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [names : CloneNameSet]
  [acc : CloneNameSet]) : CloneNameSet
  (clone-fixpoint-step-in-module pools decls names acc (clone-root-module-id)))

;; Initial over-approximation: every enum/struct name is assumed clone-able.
(define (clone-all-type-names-in-module
  [decls : ast.AstDeclList]
  [acc : CloneNameSet]
  [module-id : i64]) : CloneNameSet
  (let
    [out : CloneNameSet acc]
    [current-module-id : i64 module-id]
    [index : i64 0]
    [count : i64 (ast.ast-decl-list-len (& decls))]
    [decl-offset : i64 (struct-get decls offset)]
    (begin
      (while (< index count)
        (begin
          ;; Same borrowed classification as the fixpoint step above.
          (if (ast.ast-decl-list-unwrapped-module-or-type-definition-at?
            (& decls)
            index)
            (match (ast.ast-decl-unwrapped
              (array-ref (struct-get decls slots) (+ decl-offset index)))
              [(ast.AstDecl.Module next-module)
                (set! current-module-id next-module)]
              [(ast.AstDecl.DefEnum decl-meta name _ _)
                (set!
                  out
                  (clone-name-set-insert-id
                    out
                    (clone-name-key-id-in-module current-module-id name)))]
              [(ast.AstDecl.DefStruct decl-meta name _ _ _)
                (set!
                  out
                  (clone-name-set-insert-id
                    out
                    (clone-name-key-id-in-module current-module-id name)))]
              [_ unit])
            unit)
          (set! index (+ index 1))))
      out)))

(define (clone-all-type-names [decls : ast.AstDeclList] [acc : CloneNameSet]) : CloneNameSet
  (clone-all-type-names-in-module decls acc (clone-root-module-id)))

(define (clone-fixpoint
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [names : CloneNameSet]) : CloneNameSet
  (let
    [next : CloneNameSet
      (clone-fixpoint-step
        pools
        decls
        names
        (clone-name-set-with-capacity
          (clone-name-set-capacity names)
          (clone-name-set-aliases names)))]
    (if (= (clone-name-set-len next) (clone-name-set-len names))
      next
      (clone-fixpoint pools decls next))))

(define (clone-decl-list-append
  [left : ast.AstDeclList]
  [right : ast.AstDeclList]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity
        (+ (ast.ast-decl-list-len (& left)) (ast.ast-decl-list-len (& right))))]
    (begin
      (ast.ast-decl-list-append-from (&mut out) (& left) 0)
      (ast.ast-decl-list-append-from (&mut out) (& right) 0)
      out)))

(define (clone-root-add-type-list
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [types : ast.AstTypeList]
  [module-id : i64]) : CloneRootEntries
  (clone-root-add-type-list-at pools decls able roots (& types) module-id 0))

(define (clone-root-add-type-list-at
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [types : (& types ast.AstTypeList)]
  [module-id : i64]
  [index : i64]) : CloneRootEntries
  (if (>= index (ast.ast-type-list-len types))
    roots
    (clone-root-add-type-list-at
      pools
      decls
      able
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get
          pools
          (ast.ast-type-list-get types index (ast.ast-type-id-fallback)))
        module-id)
      types
      module-id
      (+ index 1))))

(define (clone-root-add-fields
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [fields : ast.AstFieldDefList]
  [module-id : i64]) : CloneRootEntries
  (clone-root-add-fields-at pools decls able roots (& fields) module-id 0))

(define (clone-root-add-fields-at
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [fields : (& fields ast.AstFieldDefList)]
  [module-id : i64]
  [index : i64]) : CloneRootEntries
  (if (>= index (ast.ast-field-def-list-len fields))
    roots
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(ast.AstFieldDef.Def _ ty _)
        (clone-root-add-fields-at
          pools
          decls
          able
          (clone-root-add-type pools decls able roots ty module-id)
          fields
          module-id
          (+ index 1))])))

(define (clone-root-add-variants
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [variants : ast.AstVariantDefList]
  [module-id : i64]) : CloneRootEntries
  (clone-root-add-variants-at pools decls able roots (& variants) module-id 0))

(define (clone-root-add-variants-at
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [variants : (& variants ast.AstVariantDefList)]
  [module-id : i64]
  [index : i64]) : CloneRootEntries
  (if (>= index (ast.ast-variant-def-list-len variants))
    roots
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(ast.AstVariantDef.Def _ fields _)
        (clone-root-add-variants-at
          pools
          decls
          able
          (clone-root-add-type-list pools decls able roots fields module-id)
          variants
          module-id
          (+ index 1))])))

(define (clone-root-add-name-deps-in-module
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [cursor : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [name-key-id : i64]
  [module-id : i64]) : CloneRootEntries
  ;; Index cursor rather than `ast-decl-list-step`, which this loop called TWICE
  ;; per declaration -- once to test the cursor for emptiness and once to read
  ;; its head -- so each declaration paid two 104 B row copies and two 144 B
  ;; step results to answer a tag question. Only module markers and the two
  ;; type-definition kinds carry a payload the search reads; the rest are
  ;; skipped through the borrowed tag test.
  (let
    [count : i64 (ast.ast-decl-list-len (& cursor))]
    [index : i64 0]
    [out : CloneRootEntries roots]
    [current-module-id : i64 module-id]
    [done : bool false]
    (begin
      (while (and (not done) (< index count))
        (begin
          (if (ast.ast-decl-list-unwrapped-module-or-type-definition-at?
            (& cursor)
            index)
            (match (ast.ast-decl-unwrapped
              (ast.ast-decl-list-get (& cursor) index (ast.ast-decl-fallback)))
              [(ast.AstDecl.Module next-module)
                (set! current-module-id next-module)]
              [(ast.AstDecl.DefEnum decl-meta decl-name _ variants)
                (if (=
                  (clone-name-key-id-in-module current-module-id decl-name)
                  name-key-id)
                  (begin
                    (set!
                      out
                      (clone-root-add-variants
                        pools
                        decls
                        able
                        out
                        variants
                        current-module-id))
                    (set! done true))
                  unit)]
              [(ast.AstDecl.DefStruct decl-meta decl-name _ _ fields)
                (if (=
                  (clone-name-key-id-in-module current-module-id decl-name)
                  name-key-id)
                  (begin
                    (set!
                      out
                      (clone-root-add-fields
                        pools
                        decls
                        able
                        out
                        fields
                        current-module-id))
                    (set! done true))
                  unit)]
              [_ unit])
            unit)
          (set! index (+ index 1))))
      out)))

(define (clone-root-add-name-deps
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [cursor : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [name-key-id : i64]) : CloneRootEntries
  (clone-root-add-name-deps-in-module
    pools
    decls
    cursor
    able
    roots
    name-key-id
    (clone-root-module-id)))

(define (clone-root-add-name
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [name-key-id : i64]) : CloneRootEntries
  (if (clone-name-set-contains-id? able name-key-id)
    (let
      [with-name : CloneRootEntries
        (clone-root-entries-add-id roots name-key-id)]
      (if (= (clone-root-entries-len with-name) (clone-root-entries-len roots))
        roots
        (clone-root-add-name-deps pools decls decls able with-name name-key-id)))
    roots))

(define (clone-root-add-type
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [ty : ast.AstType]
  [module-id : i64]) : CloneRootEntries
  (match ty
    [(ast.AstType.Tuple elems)
      (clone-root-add-type-list
        pools
        decls
        able
        roots
        (box-get elems)
        module-id)]
    [(ast.AstType.Array elem _)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module-id)]
    [(ast.AstType.DynArray elem)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module-id)]
    [(ast.AstType.Slice elem)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module-id)]
    [(ast.AstType.Box elem)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module-id)]
    [(ast.AstType.Region _ inner)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools inner)
        module-id)]
    [(ast.AstType.Var name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-root-nominal-key-id able module-id name))]
    [(ast.AstType.Enum name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-root-nominal-key-id able module-id name))]
    [(ast.AstType.Struct name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-root-nominal-key-id able module-id name))]
    [_ roots]))

(define (clone-root-expand
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]
  [cursor : CloneRootEntries]) : CloneRootEntries
  (let
    [out : CloneRootEntries roots]
    [index : i64 0]
    [count : i64 (clone-root-entries-len cursor)]
    (begin
      (while (< index count)
        (let
          [name-key-id : i64 (clone-root-entries-key-id-at-or cursor index -1)]
          (begin
            (set!
              out
              (clone-root-add-name-deps
                pools
                decls
                decls
                able
                (clone-root-add-name pools decls able out name-key-id)
                name-key-id))
            (set! index (+ index 1)))))
      out)))

(define (clone-stdlib-handoff-roots
  [pools : ast.AstNodePoolContext]
  [decls : ast.AstDeclList]
  [able : CloneNameSet]
  [roots : CloneRootEntries]) : CloneRootEntries
  (clone-root-expand pools decls able roots roots))

(define (clone-helper-decl-count-in-module
  [decls : ast.AstDeclList]
  [root-key-id : i64]
  [helper-name-id : i64]
  [module-id : i64]) : i64
  (match (ast.ast-decl-list-step decls)
    [(ast.AstDeclListStep.Nil) 0]
    [(ast.AstDeclListStep.Cons decl rest)
      (match (ast.ast-decl-unwrapped decl)
        [(ast.AstDecl.Module next-module)
          (clone-helper-decl-count-in-module
            rest
            root-key-id
            helper-name-id
            next-module)]
        [(ast.AstDecl.DefFn decl-meta name _ _ _ _)
          (+
            (if (and
              (=
                module-id
                (if (clone-name-key-qualified? root-key-id)
                  (clone-name-key-module-id root-key-id)
                  cbi.compiler-builtin-id-fix-empty))
              (= name helper-name-id))
              1
              0)
            (clone-helper-decl-count-in-module
              rest
              root-key-id
              helper-name-id
              module-id))]
        [_
          (clone-helper-decl-count-in-module
            rest
            root-key-id
            helper-name-id
            module-id)])]))

(define (clone-helper-decl-count
  [decls : ast.AstDeclList]
  [root-key-id : i64]
  [helper-name-id : i64]) : i64
  (clone-helper-decl-count-in-module
    decls
    root-key-id
    helper-name-id
    cbi.compiler-builtin-id-fix-empty))

(define (clone-root-entries-to-set
  [names : CloneRootEntries]
  [acc : CloneNameSet]) : CloneNameSet
  (let
    [index : i64 0]
    [count : i64 (clone-root-entries-len names)]
    [out : CloneNameSet acc]
    (begin
      (while (< index count)
        (begin
          (set!
            out
            (clone-name-set-insert-id
              out
              (clone-root-entries-key-id-at-or names index -1)))
          (set! index (+ index 1))))
      out)))