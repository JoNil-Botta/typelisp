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
(import "compiler_ast_types.tl")
(import compiler_builtin_ids as cbi)
(import compiler_intern as ci)
(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as clone_id_map)
(import stdlib.string)

(defstruct CloneNameSet
  (map clone_id_map.Map)
  (aliases clone_id_map.Map))

(defenum CloneNameList
  (Nil)
  ;; Nominal type key and the generated helper identity created for that key.
  (ConsId i64 i64 (Box CloneNameList)))

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
  (ci.intern-composite-pair-left-id key-id))

(define (clone-name-key-base-id [key-id : i64]) : i64
  (if (clone-name-key-qualified? key-id)
    (ci.intern-composite-pair-right-id key-id)
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
    [(and
        (>= name-id 0)
        (< name-id (ci.intern-capacity))
        (ci.intern-qualified? name-id))
      (clone-name-pair-key-id
        (ci.intern-qualified-module-id name-id)
        (ci.intern-qualified-base-id name-id))]
    [(or
        (clone-module-id-root? module-id)
        (and
          (>= name-id 0)
          (< name-id (ci.intern-capacity))
          (ci.intern-dotted? name-id)))
      name-id]
    [else (clone-name-pair-key-id module-id name-id)]))

(define (clone-name-key-id [name-id : i64]) : i64
  (clone-name-key-id-in-module (clone-root-module-id) name-id))

(define (clone-name-key-string [key-id : i64]) : String
  (if (clone-name-key-qualified? key-id)
    (string.append
      (ci.intern-str (clone-name-key-module-id key-id))
      (string.append "/" (ci.intern-str (clone-name-key-base-id key-id))))
    (if (and (>= key-id 0) (< key-id (ci.intern-capacity)))
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

(define (clone-type-name-has-dot? [name : String]) : bool
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    [found : bool false]
    (begin
      (while (and (not found) (< i n))
        (if (= (cast (string.string-ref name i) : i64) (cast '.' : i64))
          (set! found true)
          (set! i (+ i 1))))
      found)))

(define (clone-type-name-first-dot [name : String]) : i64
  (let
    [i : i64 0]
    [n : i64 (string.string-length name)]
    (begin
      (while (< i n)
        (if (= (cast (string.string-ref name i) : i64) (cast '.' : i64))
          (return i)
          (set! i (+ i 1))))
      -1)))

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

(define (clone-type-name-canonical [module : String] [name : String]) : String
  (if (or
    (string.eq module "")
    (>= (clone-type-name-last-slash name) 0)
    (clone-type-name-has-dot? name))
    name
    (string.append (string.append module "/") name)))

(define (clone-import-alias-key-id [module-id : i64] [alias-id : i64]) : i64
  (clone-name-key-id-in-module module-id alias-id))

(define (clone-type-name-resolve-id
  [names : CloneNameSet]
  [module-id : i64]
  [name-id : i64]) : i64
  (if (and
    (>= name-id 0)
    (< name-id (ci.intern-capacity))
    (ci.intern-dotted? name-id))
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

(define (clone-name-set-for-decls [decls : AstDeclList]) : CloneNameSet
  (let
    [aliases : clone_id_map.Map (clone_id_map.with-capacity 64)]
    [current-module-id : i64 (clone-root-module-id)]
    [index : i64 0]
    [count : i64 (ast-decl-list-len (& decls))]
    (begin
      (while (< index count)
        (begin
          (match (ast-decl-unwrapped
            (ast-decl-list-get (& decls) index (ast-decl-fallback)))
            [(AstDecl.Module next-module) (set! current-module-id next-module)]
            [(AstDecl.Import
                decl-meta
                (AstImportSpec.Spec
                  _
                  _
                  (AstMaybeModuleName.Some target)
                  (AstMaybeImportAlias.Some alias)
                  _))
              (clone_id_map.insert-ref!
                (&mut aliases)
                (clone-import-alias-key-id current-module-id alias)
                target)]
            [_ unit])
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

(define (clone-name-set-contains-resolved-nominal-id?
  [names : CloneNameSet]
  [module-id : i64]
  [name-id : i64]) : bool
  (if (clone-name-set-contains-id?
    names
    (clone-type-name-resolve-id names module-id name-id))
    true
    (if (or
      (clone-module-id-root? module-id)
      (>= name-id (ci.intern-capacity))
      (and (>= name-id 0) (ci.intern-qualified? name-id))
      (and (>= name-id 0) (ci.intern-dotted? name-id)))
      false
      (clone-name-set-contains-id? names (clone-name-key-id name-id)))))

(define (clone-name-list-cons-id [key-id : i64] [rest : CloneNameList]) : CloneNameList
  (CloneNameList.ConsId
    key-id
    (clone-helper-name-id-new-for-key key-id)
    (box rest)))

(define (clone-name-list-helper-id-or
  [names : CloneNameList]
  [key-id : i64]
  [fallback : i64]) : i64
  (let
    [cur : CloneNameList names]
    [result : i64 fallback]
    [done : bool false]
    (begin
      (while (and
        (not done)
        (match cur
          [(CloneNameList.Nil) false]
          [_ true]))
        (match cur
          [(CloneNameList.Nil) unit]
          [(CloneNameList.ConsId head helper-id rest)
            (if (= head key-id)
              (begin
                (set! result helper-id)
                (set! done true))
              (set! cur (box-get rest)))]))
      result)))

;; Recover an imported nominal's canonical key when a generated declaration
;; retains only its unqualified base name. Ambiguous bases deliberately fail:
;; the lowerer must never bind a clone call to the wrong module's helper.
(define (clone-name-list-unique-key-for-base-id-or
  [names : CloneNameList]
  [base-id : i64]
  [fallback : i64]) : i64
  (let
    [cur : CloneNameList names]
    [result : i64 fallback]
    [found : bool false]
    [ambiguous : bool false]
    (begin
      (while (and
        (not ambiguous)
        (match cur
          [(CloneNameList.Nil) false]
          [_ true]))
        (match cur
          [(CloneNameList.Nil) unit]
          [(CloneNameList.ConsId head _ rest)
            (begin
              (if (= (clone-name-key-base-id head) base-id)
                (if found
                  (set! ambiguous true)
                  (begin
                    (set! result head)
                    (set! found true)))
                unit)
              (set! cur (box-get rest)))]))
      (if ambiguous
        fallback
        result))))

(define (clone-name-list-contains-id? [names : CloneNameList] [key-id : i64]) : bool
  (let
    [cur : CloneNameList names]
    [found : bool false]
    (begin
      (while (and
        (not found)
        (match cur
          [(CloneNameList.Nil) false]
          [_ true]))
        (match cur
          [(CloneNameList.Nil) unit]
          [(CloneNameList.ConsId head _ rest)
            (if (= head key-id)
              (set! found true)
              (set! cur (box-get rest)))]))
      found)))

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
    [unique : CloneNameList
      (CloneNameList.ConsId first-key 1 (box (CloneNameList.Nil)))]
    [ambiguous : CloneNameList (CloneNameList.ConsId second-key 2 (box unique))]
    (and
      (not (clone-name-set-contains-id? one 2))
      (clone-name-set-contains-id? one 1)
      (= (clone-name-set-len dupe) 1)
      (= (clone-name-set-len grown) 11)
      (=
        (clone-name-list-unique-key-for-base-id-or unique base-id -1)
        first-key)
      (= (clone-name-list-unique-key-for-base-id-or ambiguous base-id -1) -1)
      (> (clone-name-set-capacity grown) seed-capacity))))

(define (clone-type-get [pools : AstNodePoolContext] [id : i64]) : AstType
  (ast-node-pool-context-type-get pools id))

(define (clone-expr-push [pools : AstNodePoolContext] [expr : AstExpr]) : i64
  (ast-node-pool-context-expr-push pools expr))

;; A field type is clone-able given the current clone-able-name set: scalars,
;; String, tuples, fixed arrays, and dynamic arrays are clone-able recursively; a
;; named type (parsed as AstType.Var, or resolved to AstType.Enum/AstType.Struct) is
;; clone-able iff it is in `names`; everything else is not.
(define (clone-field-type-able-id?
  [pools : AstNodePoolContext]
  [ty : AstType]
  [names : CloneNameSet]
  [module-id : i64]) : bool
  (match ty
    [(AstType.I64) true]
    [(AstType.I32) true]
    [(AstType.I16) true]
    [(AstType.I8) true]
    [(AstType.U64) true]
    [(AstType.U32) true]
    [(AstType.U16) true]
    [(AstType.U8) true]
    [(AstType.F64) true]
    [(AstType.F32) true]
    [(AstType.Bool) true]
    [(AstType.Char) true]
    [(AstType.Unit) true]
    [(AstType.Never) true]
    [(AstType.String) true]
    [(AstType.Tuple elems)
      (clone-field-type-list-able? pools (box-get elems) names module-id)]
    [(AstType.Array elem _)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools elem)
        names
        module-id)]
    [(AstType.DynArray elem)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools elem)
        names
        module-id)]
    [(AstType.Box elem)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools elem)
        names
        module-id)]
    [(AstType.Region _ inner)
      (clone-field-type-able-id?
        pools
        (clone-type-get pools inner)
        names
        module-id)]
    [(AstType.Var name)
      (clone-name-set-contains-id?
        names
        (clone-type-name-resolve-id names module-id name))]
    [(AstType.Enum name)
      (clone-name-set-contains-resolved-nominal-id? names module-id name)]
    [(AstType.Struct name)
      (clone-name-set-contains-resolved-nominal-id? names module-id name)]
    [_ false]))

(define (clone-field-type-list-able?
  [pools : AstNodePoolContext]
  [types : AstTypeList]
  [names : CloneNameSet]
  [module-id : i64]) : bool
  (clone-field-type-list-able-at pools (& types) names module-id 0))

(define (clone-field-type-list-able-at
  [pools : AstNodePoolContext]
  [types : (& types AstTypeList)]
  [names : CloneNameSet]
  [module-id : i64]
  [index : i64]) : bool
  (if (>= index (ast-type-list-len types))
    true
    (if (clone-field-type-able-id?
      pools
      (clone-type-get
        pools
        (ast-type-list-get types index (ast-type-id-fallback)))
      names
      module-id)
      (clone-field-type-list-able-at pools types names module-id (+ index 1))
      false)))

(define (clone-variant-list-able?
  [pools : AstNodePoolContext]
  [variants : AstVariantDefList]
  [names : CloneNameSet]
  [module-id : i64]) : bool
  (clone-variant-list-able-at pools (& variants) names module-id 0))

(define (clone-variant-list-able-at
  [pools : AstNodePoolContext]
  [variants : (& variants AstVariantDefList)]
  [names : CloneNameSet]
  [module-id : i64]
  [index : i64]) : bool
  (if (>= index (ast-variant-def-list-len variants))
    true
    (match (ast-variant-def-list-get variants index (ast-variant-def-fallback))
      [(AstVariantDef.Def _ field-types _)
        (if (clone-field-type-list-able? pools field-types names module-id)
          (clone-variant-list-able-at
            pools
            variants
            names
            module-id
            (+ index 1))
          false)])))

(define (clone-struct-fields-able?
  [pools : AstNodePoolContext]
  [fields : AstFieldDefList]
  [names : CloneNameSet]
  [module-id : i64]) : bool
  (clone-struct-fields-able-at pools (& fields) names module-id 0))

(define (clone-struct-fields-able-at
  [pools : AstNodePoolContext]
  [fields : (& fields AstFieldDefList)]
  [names : CloneNameSet]
  [module-id : i64]
  [index : i64]) : bool
  (if (>= index (ast-field-def-list-len fields))
    true
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ ty _)
        (if (clone-field-type-able-id? pools ty names module-id)
          (clone-struct-fields-able-at pools fields names module-id (+ index 1))
          false)])))

;; One fixpoint step: keep only names whose declaration's fields are all
;; clone-able under the current `names` set. Repeats until the set stops
;; shrinking (monotone decreasing, so it terminates).
(define (clone-fixpoint-step-in-module
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [names : CloneNameSet]
  [acc : CloneNameSet]
  [module-id : i64]) : CloneNameSet
  (let
    [out : CloneNameSet acc]
    [current-module-id : i64 module-id]
    [index : i64 0]
    [count : i64 (ast-decl-list-len (& decls))]
    [decl-offset : i64 (struct-get decls offset)]
    (begin
      (while (< index count)
        (let
          [decl : AstDecl
            (array-ref (struct-get decls slots) (+ decl-offset index))]
          (begin
            (match (ast-decl-unwrapped decl)
              [(AstDecl.Module next-module)
                (set! current-module-id next-module)]
              [(AstDecl.DefEnum decl-meta name _ variants)
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
              [(AstDecl.DefStruct decl-meta name _ _ fields)
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
            (set! index (+ index 1)))))
      out)))

(define (clone-fixpoint-step
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [names : CloneNameSet]
  [acc : CloneNameSet]) : CloneNameSet
  (clone-fixpoint-step-in-module pools decls names acc (clone-root-module-id)))

;; Initial over-approximation: every enum/struct name is assumed clone-able.
(define (clone-all-type-names-in-module
  [decls : AstDeclList]
  [acc : CloneNameSet]
  [module-id : i64]) : CloneNameSet
  (let
    [out : CloneNameSet acc]
    [current-module-id : i64 module-id]
    [index : i64 0]
    [count : i64 (ast-decl-list-len (& decls))]
    [decl-offset : i64 (struct-get decls offset)]
    (begin
      (while (< index count)
        (let
          [decl : AstDecl
            (array-ref (struct-get decls slots) (+ decl-offset index))]
          (begin
            (match (ast-decl-unwrapped decl)
              [(AstDecl.Module next-module)
                (set! current-module-id next-module)]
              [(AstDecl.DefEnum decl-meta name _ _)
                (set!
                  out
                  (clone-name-set-insert-id
                    out
                    (clone-name-key-id-in-module current-module-id name)))]
              [(AstDecl.DefStruct decl-meta name _ _ _)
                (set!
                  out
                  (clone-name-set-insert-id
                    out
                    (clone-name-key-id-in-module current-module-id name)))]
              [_ unit])
            (set! index (+ index 1)))))
      out)))

(define (clone-all-type-names [decls : AstDeclList] [acc : CloneNameSet]) : CloneNameSet
  (clone-all-type-names-in-module decls acc (clone-root-module-id)))

(define (clone-fixpoint
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
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

(define (clone-decl-list-append [left : AstDeclList] [right : AstDeclList]) : AstDeclList
  (let
    [out : AstDeclList
      (ast-decl-list-with-capacity
        (+ (ast-decl-list-len (& left)) (ast-decl-list-len (& right))))]
    (begin
      (ast-decl-list-append-from (&mut out) (& left) 0)
      (ast-decl-list-append-from (&mut out) (& right) 0)
      out)))

(define (clone-root-add-type-list
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [types : AstTypeList]
  [module-id : i64]) : CloneNameList
  (clone-root-add-type-list-at pools decls able roots (& types) module-id 0))

(define (clone-root-add-type-list-at
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [types : (& types AstTypeList)]
  [module-id : i64]
  [index : i64]) : CloneNameList
  (if (>= index (ast-type-list-len types))
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
          (ast-type-list-get types index (ast-type-id-fallback)))
        module-id)
      types
      module-id
      (+ index 1))))

(define (clone-root-add-fields
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [fields : AstFieldDefList]
  [module-id : i64]) : CloneNameList
  (clone-root-add-fields-at pools decls able roots (& fields) module-id 0))

(define (clone-root-add-fields-at
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [fields : (& fields AstFieldDefList)]
  [module-id : i64]
  [index : i64]) : CloneNameList
  (if (>= index (ast-field-def-list-len fields))
    roots
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ ty _)
        (clone-root-add-fields-at
          pools
          decls
          able
          (clone-root-add-type pools decls able roots ty module-id)
          fields
          module-id
          (+ index 1))])))

(define (clone-root-add-variants
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [variants : AstVariantDefList]
  [module-id : i64]) : CloneNameList
  (clone-root-add-variants-at pools decls able roots (& variants) module-id 0))

(define (clone-root-add-variants-at
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [variants : (& variants AstVariantDefList)]
  [module-id : i64]
  [index : i64]) : CloneNameList
  (if (>= index (ast-variant-def-list-len variants))
    roots
    (match (ast-variant-def-list-get variants index (ast-variant-def-fallback))
      [(AstVariantDef.Def _ fields _)
        (clone-root-add-variants-at
          pools
          decls
          able
          (clone-root-add-type-list pools decls able roots fields module-id)
          variants
          module-id
          (+ index 1))])))

(define (clone-root-add-name-deps-in-module
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [cursor : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [name-key-id : i64]
  [module-id : i64]) : CloneNameList
  (let
    [cur : AstDeclList cursor]
    [out : CloneNameList roots]
    [current-module-id : i64 module-id]
    [done : bool false]
    (begin
      (while (and
        (not done)
        (match (ast-decl-list-step cur)
          [(AstDeclListStep.Nil) false]
          [_ true]))
        (match (ast-decl-list-step cur)
          [(AstDeclListStep.Nil) unit]
          [(AstDeclListStep.Cons decl rest)
            (let
              [rest : AstDeclList rest]
              (match (ast-decl-unwrapped decl)
                [(AstDecl.Module next-module)
                  (begin
                    (set! current-module-id next-module)
                    (set! cur rest))]
                [(AstDecl.DefEnum decl-meta decl-name _ variants)
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
                    (set! cur rest))]
                [(AstDecl.DefStruct decl-meta decl-name _ _ fields)
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
                    (set! cur rest))]
                [_ (set! cur rest)]))]))
      out)))

(define (clone-root-add-name-deps
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [cursor : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [name-key-id : i64]) : CloneNameList
  (clone-root-add-name-deps-in-module
    pools
    decls
    cursor
    able
    roots
    name-key-id
    (clone-root-module-id)))

(define (clone-root-add-name
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [name-key-id : i64]) : CloneNameList
  (if (clone-name-set-contains-id? able name-key-id)
    (if (clone-name-list-contains-id? roots name-key-id)
      roots
      (clone-root-add-name-deps
        pools
        decls
        decls
        able
        (clone-name-list-cons-id name-key-id roots)
        name-key-id))
    roots))

(define (clone-root-add-type
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [ty : AstType]
  [module-id : i64]) : CloneNameList
  (match ty
    [(AstType.Tuple elems)
      (clone-root-add-type-list
        pools
        decls
        able
        roots
        (box-get elems)
        module-id)]
    [(AstType.Array elem _)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module-id)]
    [(AstType.DynArray elem)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module-id)]
    [(AstType.Box elem)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module-id)]
    [(AstType.Region _ inner)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools inner)
        module-id)]
    [(AstType.Var name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-type-name-resolve-id able module-id name))]
    [(AstType.Enum name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-type-name-resolve-id able module-id name))]
    [(AstType.Struct name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-type-name-resolve-id able module-id name))]
    [_ roots]))

(define (clone-root-expand
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [cursor : CloneNameList]) : CloneNameList
  (let
    [cur : CloneNameList cursor]
    [out : CloneNameList roots]
    (begin
      (while (match cur
        [(CloneNameList.Nil) false]
        [_ true])
        (match cur
          [(CloneNameList.Nil) unit]
          [(CloneNameList.ConsId name-key-id _ rest)
            (let
              [with-name : CloneNameList
                (clone-root-add-name pools decls able out name-key-id)]
              (begin
                (set!
                  out
                  (clone-root-add-name-deps
                    pools
                    decls
                    decls
                    able
                    with-name
                    name-key-id))
                (set! cur (box-get rest))))]))
      out)))

(define (clone-stdlib-handoff-roots
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]) : CloneNameList
  (clone-root-expand pools decls able roots roots))

(define (clone-helper-decl-count-in-module
  [decls : AstDeclList]
  [root-key-id : i64]
  [helper-name-id : i64]
  [module-id : i64]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons decl rest)
      (match (ast-decl-unwrapped decl)
        [(AstDecl.Module next-module)
          (clone-helper-decl-count-in-module
            rest
            root-key-id
            helper-name-id
            next-module)]
        [(AstDecl.DefFn decl-meta name _ _ _ _)
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
  [decls : AstDeclList]
  [root-key-id : i64]
  [helper-name-id : i64]) : i64
  (clone-helper-decl-count-in-module
    decls
    root-key-id
    helper-name-id
    cbi.compiler-builtin-id-fix-empty))

(define (clone-name-list-to-set [names : CloneNameList] [acc : CloneNameSet]) : CloneNameSet
  (let
    [cur : CloneNameList names]
    [out : CloneNameSet acc]
    (begin
      (while (match cur
        [(CloneNameList.Nil) false]
        [_ true])
        (match cur
          [(CloneNameList.Nil) unit]
          [(CloneNameList.ConsId name-key-id _ rest)
            (begin
              (set! out (clone-name-set-insert-id out name-key-id))
              (set! cur (box-get rest)))]))
      out)))