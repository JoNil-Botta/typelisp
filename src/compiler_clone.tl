;; compiler_clone.tl - compiler clone semantics and reachable-helper planning.
;;
;; `(clone x)` is the canonical deep-copy and the canonical way to escape an
;; arena. The lowerer dispatches `(clone x)` to `clone$<type-of-x>` for named
;; aggregate types (enums/structs); strings copy their buffer via `substring`
;; and scalars are returned as-is. The compiler computes the whole-program
;; clone-ability fixed point, records canonical nominal and helper identities,
;; and expands roots observed during typechecking to their exact reachable
;; named-aggregate closure. It also validates the generated declarations and
;; reports producer conflicts. `stdlib.clone/synthesize-helpers` is the sole
;; helper-declaration producer; this module does not construct or prepend AST.
;;
;; Clone-able values are scalars, String, tuples, fixed arrays, dynamic arrays,
;; Box of a clone-able type, and clone-able named aggregates. Function,
;; reference, raw-pointer, str, and compile-time-only values are not clone-able.
(import stdlib.str_cat_runtime as str_cat)
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
;; Snapshots share the store (and its dense buffer) while retaining their own
;; start/length pair across appends and geometric growth.
(defstruct CloneRootEntryStore
  (entries (__tl_dyn-array CloneRootEntry))
  (len i64)
  (key-index clone_id_map.Map)
  (arena i64))

;; A Dense snapshot names its arena-allocated store by address, so snapshots
;; are Copy scalar handles (the sym_i64_env idiom) and every holder shares the
;; one dense buffer: (store address, physical start, logical length).
(defenum CloneRootEntries
  (Empty)
  (Dense u64 i64 i64))

(define (clone-helper-name-id-new-for-key [type-key-id : i64]) : i64
  (ci.intern-generated-role-symbol-id
    (ci.intern-generated-symbol-role-clone-helper)
    type-key-id))

(define (clone-helper-name-id-materialize-for-key!
  [type-key-id : i64]
  [helper-id : i64]) : String
  (ci.intern-generated-role-symbol-materialize!
    (ci.intern-generated-symbol-role-clone-helper)
    helper-id
    (&
      (clone-local-helper-name
        (ci.intern-str (clone-name-key-base-id type-key-id))))))

(define (clone-root-entries-materialize-helper-names!
  [roots : CloneRootEntries]) : unit
  (let
    [index : i64 0]
    [count : i64 (clone-root-entries-len roots)]
    (while (< index count)
      (begin
        (clone-helper-name-id-materialize-for-key!
          (clone-root-entries-key-id-at-or roots index -1)
          (clone-root-entries-helper-id-at-or roots index -1))
        unit)
      (set! index (+ index 1)))))

(define (clone-root-module-id) : i64
  -1)

(define (clone-module-id-root? [module-id : i64]) : bool
  (or
    (< module-id 0)
    (=
      (string.string-length
        (ci.intern-syntax-name-text-or module-id "<structural-module>"))
      0)))

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
    [(not (ci.intern-renderable-id? name-id)) name-id]
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
    (str_cat.str-cat
      (ci.intern-str (clone-name-key-module-id key-id))
      "/"
      (ci.intern-str (clone-name-key-base-id key-id)))
    (if (ci.intern-renderable-id? key-id)
      (ci.intern-str key-id)
      "<structural-name>")))

(define (clone-type-name-last-slash [name : (& name str)]) : i64
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [last : i64 -1]
    (while (< i n)
      (if (= (cast (string.string-ref name i) : i64) (cast '/' : i64))
        (set! last i)
        unit)
      (set! i (+ i 1)))
    last))

(define (clone-type-name-module [name : (& name str)]) : String
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
  [names : (& names CloneNameSet)]
  [module-id : i64]
  [name-id : i64]) : i64
  (if (and (ci.intern-renderable-id? name-id) (ci.intern-dotted? name-id))
    (let
      [aliases : clone_id_map.Map names.aliases]
      [alias-id : i64 (ci.intern-leading-dot-id name-id)]
      [key-id : i64 (clone-import-alias-key-id module-id alias-id)]
      (match (clone_id_map.get (& aliases) key-id)
        [(LookupFound target-module-id)
          (clone-name-pair-key-id
            target-module-id
            (ci.intern-dotted-tail-id name-id))]
        [(LookupMissing) (clone-name-key-id-in-module module-id name-id)]))
    (clone-name-key-id-in-module module-id name-id)))

(define (clone-local-helper-name [type-name : String]) : String
  (str_cat.str-cat "clone$" (clone-type-name-base type-name)))

(define (clone-helper-name [type-name : String]) : String
  (let
    [module : String (clone-type-name-module type-name)]
    [local : String (clone-local-helper-name type-name)]
    (if (string.eq module "")
      local
      (str_cat.str-cat module "/" local))))

(define (clone-name-set-empty) : CloneNameSet
  (CloneNameSet (clone_id_map.with-capacity 8) (clone_id_map.with-capacity 8)))

(define (clone-module-alias-import-kind? [kind : ast.AstImportKind]) : bool
  (match kind
    [(or (Module) (Macro _ _) (MacroDecls _ _)) true]
    [(or (ModuleAll) (ModuleItem _)) false]))

(define (clone-name-set-for-decls [decls : (& decls ast.AstDeclList)]) : CloneNameSet
  (let
    [aliases : clone_id_map.Map (clone_id_map.with-capacity 64)]
    [current-module-id : i64 (clone-root-module-id)]
    [index : i64 0]
    [count : i64 (ast.ast-decl-list-len decls)]
    (while (< index count)
      ;; Borrowed classification first: only module markers and imports
      ;; carry a payload this alias table reads.
      (if (ast.ast-decl-list-unwrapped-module-or-import-at? decls index)
        (match (ast.ast-decl-unwrapped
          (& (ast.ast-decl-list-get decls index (ast.ast-decl-fallback))))
          [(Module next-module) (set! current-module-id next-module)]
          [(Import decl-meta (Spec kind _ (Some target) (Some alias) _))
            (if (clone-module-alias-import-kind? kind)
              (clone_id_map.insert-ref!
                (&mut aliases)
                (clone-import-alias-key-id current-module-id alias)
                target)
              unit)]
          [_ unit])
        unit)
      (set! index (+ index 1)))
    (CloneNameSet (clone_id_map.with-capacity 8) aliases)))

;; The fixpoint rebuilds its accepted set on each step over the whole-program
;; type universe; seeding that accumulator at the input set's capacity (it can
;; only shrink relative to the input) avoids the rehash+fill-empty grow chain a
;; capacity-8 seed would walk on every step.
(define (clone-name-set-with-capacity
  [capacity : i64]
  [aliases : clone_id_map.Map]) : CloneNameSet
  (CloneNameSet (clone_id_map.with-capacity capacity) aliases))

(define (clone-name-set-insert-alias-id
  [names : CloneNameSet]
  [module-id : i64]
  [alias-id : i64]
  [target-module-id : i64]) : CloneNameSet
  (let
    [map : clone_id_map.Map names.map]
    [aliases : clone_id_map.Map names.aliases]
    (clone_id_map.insert-ref!
      (&mut aliases)
      (clone-import-alias-key-id module-id alias-id)
      target-module-id)
    (CloneNameSet map aliases)))

(define (clone-name-set-insert-id [names : CloneNameSet] [key-id : i64]) : CloneNameSet
  (let
    [map : clone_id_map.Map names.map]
    [aliases : clone_id_map.Map names.aliases]
    (if (>= key-id 0)
      (clone_id_map.insert-ref! (&mut map) key-id 1)
      unit)
    (CloneNameSet map aliases)))

(define (clone-name-set-contains-id?
  [names : (& names CloneNameSet)]
  [key-id : i64]) : bool
  (if (< key-id 0)
    false
    (clone_id_map.contains? (& names.map) key-id)))

(define (clone-name-set-contains-canonical-id?
  [names : (& names CloneNameSet)]
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
  [names : (& names CloneNameSet)]
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
  [able : (& able CloneNameSet)]
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

(define (clone-root-entries-empty? [roots : CloneRootEntries]) : bool
  (match roots
    [(Empty) true]
    [_ false]))

(define (clone-root-entries-len [roots : CloneRootEntries]) : i64
  (match roots
    [(Empty) 0]
    [(Dense _ _ len) len]))

;; The store behind a Dense snapshot, read and written whole: a shallow copy
;; whose `entries` and `key-index` handles are the shared ones. A caller that
;; changes `len`, grows `entries` or inserts into `key-index` writes its copy
;; back before anything else reads the store.
(define (clone-root-entries-store-read [address : u64]) : CloneRootEntryStore
  (unsafe
    (ptr-read (int->ptr address : (Ptr CloneRootEntryStore)))))

(define (clone-root-entries-store-write!
  [address : u64]
  [store : CloneRootEntryStore]) : unit
  (unsafe
    (ptr-write! (int->ptr address : (MutPtr CloneRootEntryStore)) store)))

;; Entry lookups are the hot read (every root walk in lowering and typecheck
;; goes through them), so they load only the store's `entries` handle, which is
;; its first field (declaration-order layout, SPEC 3.5.3), instead of copying
;; the whole store.
(define (clone-root-entries-store-entry-at-address
  [address : u64]
  [index : i64]) : CloneRootEntry
  (unsafe
    (let
      [entries : (__tl_dyn-array CloneRootEntry)
        (ptr-read (int->ptr address : (Ptr (__tl_dyn-array CloneRootEntry))))]
      (ptr-read (ptr-offset (__tl_array-data entries) index)))))

(define (clone-root-entries-store-new) : u64
  (let
    [owner : i64 (arena.tl_arena_current)]
    [store : (Box CloneRootEntryStore)
      (box
        (CloneRootEntryStore
          (__tl_make-array CloneRootEntry 4)
          0
          (clone_id_map.with-capacity 8)
          owner))]
    (unsafe
      (cast (ptr-read (ptr-cast (ptr-addr-of store) : (Ptr i64))) : u64))))

(define (clone-root-entries-store-copy-range!
  [dst : (&mut dst (__tl_dyn-array CloneRootEntry))]
  [src : (& src (__tl_dyn-array CloneRootEntry))]
  [index : i64]
  [count : i64]) : unit
  (let
    [cursor : i64 index]
    (while (< cursor count)
      (set! (array-ref dst cursor) (array-ref src cursor))
      (set! cursor (+ cursor 1)))
    unit))

(define (clone-root-entries-store-grow!
  [store : (&mut store CloneRootEntryStore)]) : unit
  (let
    [owner : i64 store.arena]
    [old-capacity : i64 (array-length store.entries)]
    [new-capacity : i64
      (if (< old-capacity 1)
        1
        (* old-capacity 2))]
    (in-arena
      (arena.Arena owner)
      (let
        [bigger : (__tl_dyn-array CloneRootEntry)
          (__tl_make-array CloneRootEntry new-capacity)]
        ;; Only the live physical prefix is copied; snapshots share the new
        ;; dense handle and retain their old start/length bounds.
        (clone-root-entries-store-copy-range!
          (&mut bigger)
          (& store.entries)
          0
          store.len)
        (set! store.entries bigger)))))

(define (clone-root-entries-store-entry-at
  [store : (& store CloneRootEntryStore)]
  [index : i64]) : CloneRootEntry
  (unsafe
    (ptr-read (ptr-offset (__tl_array-data store.entries) index))))

(define (clone-root-entries-entry-at-or
  [roots : CloneRootEntries]
  [logical-index : i64]
  [fallback : CloneRootEntry]) : CloneRootEntry
  (match roots
    [(Empty) fallback]
    [(Dense address start len)
      (if (and (>= logical-index 0) (< logical-index len))
        (clone-root-entries-store-entry-at-address
          address
          (+ start (- len (+ logical-index 1))))
        fallback)]))

(define (clone-root-entries-key-id-at-or
  [roots : CloneRootEntries]
  [logical-index : i64]
  [fallback : i64]) : i64
  (__tl-project-field
    (clone-root-entries-entry-at-or
      roots
      logical-index
      (CloneRootEntry fallback fallback))
    key-id))

(define (clone-root-entries-helper-id-at-or
  [roots : CloneRootEntries]
  [logical-index : i64]
  [fallback : i64]) : i64
  (__tl-project-field
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
    (match (clone_id_map.get (& store.key-index) key-id)
      [(LookupFound physical)
        (if (and (>= physical start) (< physical (+ start len)))
          physical
          -1)]
      [(LookupMissing) -1])))

(define (clone-root-entries-contains-id?
  [roots : CloneRootEntries]
  [key-id : i64]) : bool
  (match roots
    [(Empty) false]
    [(Dense address start len)
      (let
        [store : CloneRootEntryStore (clone-root-entries-store-read address)]
        (>=
          (clone-root-entries-store-index-in-view-or (& store) start len key-id)
          0))]))

(define (clone-root-entries-helper-id-or
  [roots : CloneRootEntries]
  [key-id : i64]
  [fallback : i64]) : i64
  (match roots
    [(Empty) fallback]
    [(Dense address start len)
      (let
        [store : CloneRootEntryStore (clone-root-entries-store-read address)]
        [physical : i64
          (clone-root-entries-store-index-in-view-or (& store) start len key-id)]
        (if (< physical 0)
          fallback
          (__tl-project-field
            (clone-root-entries-store-entry-at (& store) physical)
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
      result)))

(define (clone-root-entries-materialize-dense
  [store : (& store CloneRootEntryStore)]
  [start : i64]
  [count : i64]) : CloneRootEntries
  (let
    [out-address : u64 (clone-root-entries-store-new)]
    [out : CloneRootEntryStore (clone-root-entries-store-read out-address)]
    [index : i64 (- count 1)]
    ;; Iterate physical oldest -> newest so helper identity and map first
    ;; indices are byte-for-byte preserved.
    (while (>= index 0)
      (let
        [entry : CloneRootEntry
          (clone-root-entries-store-entry-at
            store
            (+ start (- count (+ index 1))))]
        ;; index is logical; physical materialization is easiest by writing
        ;; in reverse logical order to physical 0..len-1.
        (if (< out.len (array-length out.entries))
          unit
          (clone-root-entries-store-grow! (&mut out)))
        (let
          [physical : i64 out.len]
          (set! (array-ref out.entries physical) entry)
          (set! out.len (+ physical 1))
          (let
            [key-id : i64 entry.key-id]
            (if (not (clone_id_map.contains? (& out.key-index) key-id))
              (clone_id_map.insert-ref! (&mut out.key-index) key-id physical)
              unit))))
      (set! index (- index 1)))
    (clone-root-entries-store-write! out-address out)
    (Dense out-address 0 count)))

(define (clone-root-entries-materialize [roots : CloneRootEntries]) : CloneRootEntries
  (match roots
    [(Empty) Empty]
    [(Dense address start count)
      (let
        [store : CloneRootEntryStore (clone-root-entries-store-read address)]
        (clone-root-entries-materialize-dense (& store) start count))]))

(define (clone-root-entries-copy [roots : CloneRootEntries]) : CloneRootEntries
  (clone-root-entries-materialize roots))

(define (clone-root-entries-add-id [roots : CloneRootEntries] [key-id : i64]) : CloneRootEntries
  (match roots
    [(Empty)
      (if (< key-id 0)
        Empty
        (let
          [helper-id : i64 (clone-helper-name-id-new-for-key key-id)]
          [address : u64 (clone-root-entries-store-new)]
          [store : CloneRootEntryStore (clone-root-entries-store-read address)]
          (set! (array-ref store.entries 0) (CloneRootEntry key-id helper-id))
          (set! store.len 1)
          (clone_id_map.insert-ref! (&mut store.key-index) key-id 0)
          (clone-root-entries-store-write! address store)
          (Dense address 0 1)))]
    [(Dense address start len)
      (let
        [store : CloneRootEntryStore (clone-root-entries-store-read address)]
        [present? : bool
          (and
            (>= key-id 0)
            (>=
              (clone-root-entries-store-index-in-view-or
                (& store)
                start
                len
                key-id)
              0))]
        (if (or (< key-id 0) present?)
          roots
          (let
            [helper-id : i64 (clone-helper-name-id-new-for-key key-id)]
            [tail? : bool (and (= start 0) (= len store.len))]
            [target : CloneRootEntries
              (if tail?
                roots
                (clone-root-entries-materialize roots))]
            (match target
              [(Dense target-address target-start target-len)
                (let
                  [target-store : CloneRootEntryStore
                    (clone-root-entries-store-read target-address)]
                  [owner : i64 target-store.arena]
                  (in-arena
                    (arena.Arena owner)
                    (if (>=
                      target-store.len
                      (array-length target-store.entries))
                      (clone-root-entries-store-grow! (&mut target-store))
                      unit)
                    (let
                      [physical : i64 target-store.len]
                      (set!
                        (array-ref target-store.entries physical)
                        (CloneRootEntry key-id helper-id))
                      (set! target-store.len (+ physical 1))
                      (clone_id_map.insert-ref!
                        (&mut target-store.key-index)
                        key-id
                        physical)
                      (clone-root-entries-store-write!
                        target-address
                        target-store)
                      (Dense target-address target-start (+ target-len 1)))))]
              [(Empty) Empty]))))]))

(define (clone-root-entries-take [roots : CloneRootEntries] [count : i64]) : CloneRootEntries
  (if (<= count 0)
    Empty
    (let
      [len : i64 (clone-root-entries-len roots)]
      (if (>= count len)
        roots
        (match roots
          [(Empty) Empty]
          [(Dense address start _)
            (Dense address (+ start (- len count)) count)])))))

(define (clone-root-entries-drop [roots : CloneRootEntries] [count : i64]) : CloneRootEntries
  (if (<= count 0)
    roots
    (let
      [len : i64 (clone-root-entries-len roots)]
      (if (>= count len)
        Empty
        (match roots
          [(Empty) Empty]
          [(Dense address start _) (Dense address start (- len count))])))))

(define (clone-name-set-len [names : (& names CloneNameSet)]) : i64
  (clone_id_map.len (& names.map)))

(define (clone-name-set-capacity [names : (& names CloneNameSet)]) : i64
  (clone_id_map.capacity (& names.map)))

(define (clone-type-get [pools : (& pools ast.AstNodePoolContext)] [id : i64]) : ast.AstType
  (ast.ast-node-pool-context-type-get pools id))

;; A field type is clone-able given the current clone-able-name set: scalars,
;; String, tuples, fixed arrays, and dynamic arrays are clone-able recursively; a
;; named type (parsed as AstType.Var, or resolved to AstType.Enum/AstType.Struct) is
;; clone-able iff it is in `names`; everything else is not.
(define (clone-field-type-able-id?
  [pools : (& pools ast.AstNodePoolContext)]
  [ty : ast.AstType]
  [names : (& names CloneNameSet)]
  [module-id : i64]) : bool
  (match ty
    [(or (I64) (I32) (I16) (I8) (U64) (U32) (U16) (U8) (F64) (F32) (Bool) (Char)
         (Unit) (Never) (String))
      true]
    [(Tuple elems)
      (clone-field-type-list-able? pools (deref elems) names module-id)]
    [(or (Array elem _) (DynArray elem) (Slice elem) (Box elem) (Region _ elem))
      (clone-field-type-able-id?
        pools
        (clone-type-get pools elem)
        names
        module-id)]
    [(Var name)
      (clone-name-set-contains-id?
        names
        (clone-type-name-resolve-id names module-id name))]
    [(or (Enum name) (Struct name))
      (clone-name-set-contains-resolved-nominal-id? names module-id name)]
    [_ false]))

(define (clone-field-type-list-able?
  [pools : (& pools ast.AstNodePoolContext)]
  [types : ast.AstTypeList]
  [names : (& names CloneNameSet)]
  [module-id : i64]) : bool
  (clone-field-type-list-able-at pools (& types) names module-id 0))

(define (clone-field-type-list-able-at
  [pools : (& pools ast.AstNodePoolContext)]
  [types : (& types ast.AstTypeList)]
  [names : (& names CloneNameSet)]
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
  [pools : (& pools ast.AstNodePoolContext)]
  [variants : ast.AstVariantDefList]
  [names : (& names CloneNameSet)]
  [module-id : i64]) : bool
  (clone-variant-list-able-at pools (& variants) names module-id 0))

(define (clone-variant-list-able-at
  [pools : (& pools ast.AstNodePoolContext)]
  [variants : (& variants ast.AstVariantDefList)]
  [names : (& names CloneNameSet)]
  [module-id : i64]
  [index : i64]) : bool
  (if (>= index (ast.ast-variant-def-list-len variants))
    true
    (match (ast.ast-variant-def-list-get
      variants
      index
      (ast.ast-variant-def-fallback))
      [(Def _ field-types _)
        (if (clone-field-type-list-able? pools field-types names module-id)
          (clone-variant-list-able-at
            pools
            variants
            names
            module-id
            (+ index 1))
          false)])))

(define (clone-struct-fields-able?
  [pools : (& pools ast.AstNodePoolContext)]
  [fields : ast.AstFieldDefList]
  [names : (& names CloneNameSet)]
  [module-id : i64]) : bool
  (clone-struct-fields-able-at pools (& fields) names module-id 0))

(define (clone-struct-fields-able-at
  [pools : (& pools ast.AstNodePoolContext)]
  [fields : (& fields ast.AstFieldDefList)]
  [names : (& names CloneNameSet)]
  [module-id : i64]
  [index : i64]) : bool
  (if (>= index (ast.ast-field-def-list-len fields))
    true
    (match (ast.ast-field-def-list-get
      fields
      index
      (ast.ast-field-def-fallback))
      [(Def _ ty _)
        (if (clone-field-type-able-id? pools ty names module-id)
          (clone-struct-fields-able-at pools fields names module-id (+ index 1))
          false)])))

;; One fixpoint step: keep only names whose declaration's fields are all
;; clone-able under the current `names` set. Repeats until the set stops
;; shrinking (monotone decreasing, so it terminates).
(define (clone-fixpoint-step-in-module
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [names : (& names CloneNameSet)]
  [acc : CloneNameSet]
  [module-id : i64]) : CloneNameSet
  (let
    [out : CloneNameSet acc]
    [current-module-id : i64 module-id]
    [index : i64 0]
    [count : i64 (ast.ast-decl-list-len decls)]
    (while (< index count)
      ;; Classify through a borrow first: only module markers and the two
      ;; type-definition kinds have a payload this fixpoint reads, so every
      ;; other declaration is skipped without materialising a 104 B row and
      ;; copying it twice more through `ast-decl-unwrapped`.
      (if (ast.ast-decl-list-unwrapped-module-or-type-definition-at?
        decls
        index)
        (match (ast.ast-decl-unwrapped
          (& (ast.ast-decl-list-get decls index (ast.ast-decl-fallback))))
          [(Module next-module) (set! current-module-id next-module)]
          [(DefEnum decl-meta name _ variants)
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
          [(DefStruct decl-meta name _ _ fields)
            (if (clone-struct-fields-able? pools fields names current-module-id)
              (set!
                out
                (clone-name-set-insert-id
                  out
                  (clone-name-key-id-in-module current-module-id name)))
              unit)]
          [_ unit])
        unit)
      (set! index (+ index 1)))
    out))

(define (clone-fixpoint-step
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [names : (& names CloneNameSet)]
  [acc : CloneNameSet]) : CloneNameSet
  (clone-fixpoint-step-in-module pools decls names acc (clone-root-module-id)))

;; Initial over-approximation: every enum/struct name is assumed clone-able.
(define (clone-all-type-names-in-module
  [decls : (& decls ast.AstDeclList)]
  [acc : CloneNameSet]
  [module-id : i64]) : CloneNameSet
  (let
    [out : CloneNameSet acc]
    [current-module-id : i64 module-id]
    [index : i64 0]
    [count : i64 (ast.ast-decl-list-len decls)]
    (while (< index count)
      ;; Same borrowed classification as the fixpoint step above.
      (if (ast.ast-decl-list-unwrapped-module-or-type-definition-at?
        decls
        index)
        (match (ast.ast-decl-unwrapped
          (& (ast.ast-decl-list-get decls index (ast.ast-decl-fallback))))
          [(Module next-module) (set! current-module-id next-module)]
          [(or (DefEnum _ name _ _) (DefStruct _ name _ _ _))
            (set!
              out
              (clone-name-set-insert-id
                out
                (clone-name-key-id-in-module current-module-id name)))]
          [_ unit])
        unit)
      (set! index (+ index 1)))
    out))

(define (clone-all-type-names
  [decls : (& decls ast.AstDeclList)]
  [acc : CloneNameSet]) : CloneNameSet
  (clone-all-type-names-in-module decls acc (clone-root-module-id)))

(define (clone-fixpoint
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [names : (& names CloneNameSet)]) : CloneNameSet
  (let
    [next : CloneNameSet
      (clone-fixpoint-step
        pools
        decls
        names
        (clone-name-set-with-capacity
          (clone-name-set-capacity names)
          (clone names.aliases)))]
    (if (= (clone-name-set-len next) (clone-name-set-len names))
      next
      (clone-fixpoint pools decls next))))

(define (clone-decl-list-append
  [left : ast.AstDeclList]
  [right : (& right ast.AstDeclList)]) : ast.AstDeclList
  (let
    [out : ast.AstDeclList
      (ast.ast-decl-list-with-capacity
        (+ (ast.ast-decl-list-len (& left)) (ast.ast-decl-list-len right)))]
    (ast.ast-decl-list-append-from (&mut out) (& left) 0)
    (ast.ast-decl-list-append-from (&mut out) right 0)
    out))

(define (clone-root-add-type-list
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
  [roots : CloneRootEntries]
  [types : ast.AstTypeList]
  [module-id : i64]) : CloneRootEntries
  (clone-root-add-type-list-at pools decls able roots (& types) module-id 0))

(define (clone-root-add-type-list-at
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
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
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
  [roots : CloneRootEntries]
  [fields : ast.AstFieldDefList]
  [module-id : i64]) : CloneRootEntries
  (clone-root-add-fields-at pools decls able roots (& fields) module-id 0))

(define (clone-root-add-fields-at
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
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
      [(Def _ ty _)
        (clone-root-add-fields-at
          pools
          decls
          able
          (clone-root-add-type pools decls able roots ty module-id)
          fields
          module-id
          (+ index 1))])))

(define (clone-root-add-variants
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
  [roots : CloneRootEntries]
  [variants : ast.AstVariantDefList]
  [module-id : i64]) : CloneRootEntries
  (clone-root-add-variants-at pools decls able roots (& variants) module-id 0))

(define (clone-root-add-variants-at
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
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
      [(Def _ fields _)
        (clone-root-add-variants-at
          pools
          decls
          able
          (clone-root-add-type-list pools decls able roots fields module-id)
          variants
          module-id
          (+ index 1))])))

(define (clone-root-add-name-deps-in-module
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [cursor : (& cursor ast.AstDeclList)]
  [able : (& able CloneNameSet)]
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
    [count : i64 (ast.ast-decl-list-len cursor)]
    [index : i64 0]
    [out : CloneRootEntries roots]
    [current-module-id : i64 module-id]
    [done : bool false]
    (while (and (not done) (< index count))
      (if (ast.ast-decl-list-unwrapped-module-or-type-definition-at?
        cursor
        index)
        (match (ast.ast-decl-unwrapped
          (& (ast.ast-decl-list-get cursor index (ast.ast-decl-fallback))))
          [(Module next-module) (set! current-module-id next-module)]
          [(DefEnum decl-meta decl-name _ variants)
            (when
              (=
                (clone-name-key-id-in-module current-module-id decl-name)
                name-key-id)
              (set!
                out
                (clone-root-add-variants
                  pools
                  decls
                  able
                  out
                  variants
                  current-module-id))
              (set! done true))]
          [(DefStruct decl-meta decl-name _ _ fields)
            (when
              (=
                (clone-name-key-id-in-module current-module-id decl-name)
                name-key-id)
              (set!
                out
                (clone-root-add-fields
                  pools
                  decls
                  able
                  out
                  fields
                  current-module-id))
              (set! done true))]
          [_ unit])
        unit)
      (set! index (+ index 1)))
    out))

(define (clone-root-add-name-deps
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [cursor : (& cursor ast.AstDeclList)]
  [able : (& able CloneNameSet)]
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
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
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
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
  [roots : CloneRootEntries]
  [ty : ast.AstType]
  [module-id : i64]) : CloneRootEntries
  (match ty
    [(Tuple elems)
      (clone-root-add-type-list pools decls able roots (deref elems) module-id)]
    [(or (Array elem _) (DynArray elem) (Slice elem) (Box elem) (Region _ elem))
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module-id)]
    [(or (Var name) (Enum name) (Struct name))
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-root-nominal-key-id able module-id name))]
    [_ roots]))

(define (clone-root-expand
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
  [roots : CloneRootEntries]
  [cursor : CloneRootEntries]) : CloneRootEntries
  (let
    [out : CloneRootEntries roots]
    [index : i64 0]
    [count : i64 (clone-root-entries-len cursor)]
    (while (< index count)
      (let
        [name-key-id : i64 (clone-root-entries-key-id-at-or cursor index -1)]
        (set!
          out
          (clone-root-add-name-deps
            pools
            decls
            decls
            able
            (clone-root-add-name pools decls able out name-key-id)
            name-key-id))
        (set! index (+ index 1))))
    out))

(define (clone-stdlib-handoff-roots
  [pools : (& pools ast.AstNodePoolContext)]
  [decls : (& decls ast.AstDeclList)]
  [able : (& able CloneNameSet)]
  [roots : CloneRootEntries]) : CloneRootEntries
  (let
    [expanded : CloneRootEntries
      (clone-root-expand pools decls able roots roots)]
    ;; Clone helper identities stay structural while dependencies expand.
    ;; The declaration macro still emits textual syntax, so publish each
    ;; helper spelling once at this handoff before validation and lowering.
    (clone-root-entries-materialize-helper-names! expanded)
    expanded))

(define (clone-helper-decl-count-in-module
  [decls : ast.AstDeclList]
  [root-key-id : i64]
  [helper-name-id : i64]
  [module-id : i64]) : i64
  (match (ast.ast-decl-list-step decls)
    [(Nil) 0]
    [(Cons decl rest)
      (match (ast.ast-decl-unwrapped (& decl))
        [(Module next-module)
          (clone-helper-decl-count-in-module
            rest
            root-key-id
            helper-name-id
            next-module)]
        [(DefFn decl-meta name _ _ _ _)
          (+
            (if (and
              (if (clone-name-key-qualified? root-key-id)
                (= module-id (clone-name-key-module-id root-key-id))
                (clone-module-id-root? module-id))
              ;; The declaration macro still constructs syntax from text. At
              ;; this boundary validate its spelling in the matching module;
              ;; lowering then aliases that syntax identity to the structural
              ;; clone-helper identity carried by the root entry.
              (string.eq (ci.intern-str name) (ci.intern-str helper-name-id)))
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
    (while (< index count)
      (set!
        out
        (clone-name-set-insert-id
          out
          (clone-root-entries-key-id-at-or names index -1)))
      (set! index (+ index 1)))
    out))