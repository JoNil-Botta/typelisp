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
(import stdlib.arena)
(import stdlib.hashmap)
(import (hashmap i64 i64) as clone_id_map)
(import stdlib.string)
(cfg test (import stdlib.test))

(defstruct CloneNameSet
  (map clone_id_map.Map))

;; Generated clone helpers are identities derived from their nominal type, not
;; source tokens. Record that structural relationship while emitting helpers so
;; lowering never has to recover a helper id from its `clone$...` display name.
;; The large startup-owned table does not grow for compiler-sized programs, so
;; entries remain valid across the scratch arenas used by clone discovery.
(define clone-helper-name-ids : clone_id_map.Map
  (clone_id_map.with-capacity 65536))
(define clone-helper-acc-name-ids : clone_id_map.Map
  (clone_id_map.with-capacity 65536))
(define clone-helper-rev-name-ids : clone_id_map.Map
  (clone_id_map.with-capacity 65536))

(define (clone-helper-name-id-bind! [type-key-id : i64] [helper-name-id : i64]) : unit
  (clone_id_map.insert (&mut clone-helper-name-ids) type-key-id helper-name-id))

(define (clone-helper-name-id-for-key-or [type-key-id : i64] [fallback : i64]) : i64
  (match (clone_id_map.get (& clone-helper-name-ids) type-key-id)
    [(clone_id_map.LookupFound helper-name-id) helper-name-id]
    [(clone_id_map.LookupMissing) fallback]))

(define (clone-helper-acc-name-id-for-key-or
  [type-key-id : i64]
  [fallback : i64]) : i64
  (match (clone_id_map.get (& clone-helper-acc-name-ids) type-key-id)
    [(clone_id_map.LookupFound helper-name-id) helper-name-id]
    [(clone_id_map.LookupMissing) fallback]))

(define (clone-helper-rev-name-id-for-key-or
  [type-key-id : i64]
  [fallback : i64]) : i64
  (match (clone_id_map.get (& clone-helper-rev-name-ids) type-key-id)
    [(clone_id_map.LookupFound helper-name-id) helper-name-id]
    [(clone_id_map.LookupMissing) fallback]))

(defenum CloneNameList
  (Nil)
  (ConsId i64 (Box CloneNameList))
  ;; Transitional adapter for callers that have not yet propagated the AST id.
  ;; Clone internals never construct this variant.
  (Cons String (Box CloneNameList)))

(define (clone-root-module-id) : i64
  -1)

(define (clone-module-id-root? [module-id : i64]) : bool
  (or (< module-id 0) (= (string.string-length (ci.intern-str module-id)) 0)))

;; Pair keys live above the intern-id range, so a root name id and a
;; module-qualified `(module-id, base-id)` cannot collide.
(define (clone-name-pair-key-id [module-id : i64] [base-id : i64]) : i64
  (+ (ci.intern-capacity) (+ (* module-id (ci.intern-capacity)) base-id)))

(define (clone-name-key-qualified? [key-id : i64]) : bool
  (>= key-id (ci.intern-capacity)))

(define (clone-name-key-module-id [key-id : i64]) : i64
  (/ (- key-id (ci.intern-capacity)) (ci.intern-capacity)))

(define (clone-name-key-base-id [key-id : i64]) : i64
  (if (clone-name-key-qualified? key-id)
    (% (- key-id (ci.intern-capacity)) (ci.intern-capacity))
    key-id))

;; Preserve the old canonicalization rules without allocating or interning a
;; joined `module/name` string. Slash-qualified source ids already carry their
;; module/base ids in the interner metadata; dotted names remain atomic.
(define (clone-name-key-id-in-module [module-id : i64] [name-id : i64]) : i64
  (if (ci.intern-qualified? name-id)
    (clone-name-pair-key-id
      (ci.intern-qualified-module-id name-id)
      (ci.intern-qualified-base-id name-id))
    (if (or (clone-module-id-root? module-id) (ci.intern-dotted? name-id))
      name-id
      (clone-name-pair-key-id module-id name-id))))

(define (clone-name-key-id [name-id : i64]) : i64
  (clone-name-key-id-in-module (clone-root-module-id) name-id))

(define (clone-name-key-string [key-id : i64]) : String
  (if (clone-name-key-qualified? key-id)
    (string.append
      (ci.intern-str (clone-name-key-module-id key-id))
      (string.append "/" (ci.intern-str (clone-name-key-base-id key-id))))
    (ci.intern-str key-id)))

(define (clone-existing-name-key-id [name : String]) : i64
  (match (ci.intern-lookup-preserving-generated-id name)
    [(InternLookupFound name-id) (clone-name-key-id name-id)]
    [(InternLookupMissing) -1]))

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

(define (clone-local-helper-name [type-name : String]) : String
  (string.append "clone$" (clone-type-name-base type-name)))

(define (clone-helper-name [type-name : String]) : String
  (let
    [module : String (clone-type-name-module type-name)]
    [local : String (clone-local-helper-name type-name)]
    (if (string.eq module "")
      local
      (string.append (string.append module "/") local))))

(define (clone-short-list-variant-name? [variant-name : String]) : bool
  (or (string.eq variant-name "Nil") (string.eq variant-name "Cons")))

(define (clone-list-variant-reference-name
  [type-name : String]
  [variant-name : String]) : String
  (if (clone-short-list-variant-name? variant-name)
    (let
      [type-base : String (clone-type-name-base type-name)]
      (if (string.eq type-base variant-name)
        variant-name
        (string.append (string.append type-base ".") variant-name)))
    variant-name))

(define (clone-list-variant-reference-id
  [type-name-id : i64]
  [variant-name-id : i64]) : i64
  (let
    [type-base-id : i64 (clone-name-base-id type-name-id)]
    [type-base : String (ci.intern-str type-base-id)]
    [variant-name : String (ci.intern-str variant-name-id)]
    (if (clone-short-list-variant-name? variant-name)
      (if (string.eq type-base variant-name)
        variant-name-id
        (ci.intern-generated-dotted-name
          (string.append (string.append type-base ".") variant-name)
          type-base-id))
      variant-name-id)))

(define (clone-name-set-empty) : CloneNameSet
  (CloneNameSet (clone_id_map.with-capacity 8)))

;; The fixpoint rebuilds its accepted set on each step over the whole-program
;; type universe; seeding that accumulator at the input set's capacity (it can
;; only shrink relative to the input) avoids the rehash+fill-empty grow chain a
;; capacity-8 seed would walk on every step.
(define (clone-name-set-with-capacity [capacity : i64]) : CloneNameSet
  (CloneNameSet (clone_id_map.with-capacity capacity)))

(define (clone-name-set-map [names : CloneNameSet]) : clone_id_map.Map
  (struct-get names map))

(define (clone-name-set-insert-id [names : CloneNameSet] [key-id : i64]) : CloneNameSet
  (let
    [map (clone-name-set-map names)]
    (begin
      (if (>= key-id 0)
        (clone_id_map.insert-ref! (&mut map) key-id 1)
        unit)
      (CloneNameSet map))))

(define (clone-name-set-contains-id? [names : CloneNameSet] [key-id : i64]) : bool
  (let
    [map (clone-name-set-map names)]
    (if (< key-id 0)
      false
      (clone_id_map.contains? (& map) key-id))))

;; Compatibility adapters are lookup-only. A missing id is not synthesized in
;; this post-parse pass.
(define (clone-name-set-insert [names : CloneNameSet] [name : String]) : CloneNameSet
  (clone-name-set-insert-id names (clone-existing-name-key-id name)))

(define (clone-name-set-contains? [names : CloneNameSet] [name : String]) : bool
  (clone-name-set-contains-id? names (clone-existing-name-key-id name)))

(define (clone-name-set-contains-canonical-id?
  [names : CloneNameSet]
  [module-id : i64]
  [name-id : i64]) : bool
  (clone-name-set-contains-id?
    names
    (clone-name-key-id-in-module module-id name-id)))

(define (clone-name-set-contains-canonical?
  [names : CloneNameSet]
  [module : String]
  [name : String]) : bool
  (clone-name-set-contains? names (clone-type-name-canonical module name)))

(define (clone-name-set-contains-resolved-nominal?
  [names : CloneNameSet]
  [module : String]
  [name : String]) : bool
  (if (clone-name-set-contains-canonical? names module name)
    true
    (if (or
      (string.eq module "")
      (>= (clone-type-name-last-slash name) 0)
      (clone-type-name-has-dot? name))
      false
      (clone-name-set-contains? names name))))

(define (clone-name-set-contains-resolved-nominal-id?
  [names : CloneNameSet]
  [module-id : i64]
  [name-id : i64]) : bool
  (if (clone-name-set-contains-canonical-id? names module-id name-id)
    true
    (if (or
      (clone-module-id-root? module-id)
      (ci.intern-qualified? name-id)
      (ci.intern-dotted? name-id))
      false
      (clone-name-set-contains-id? names (clone-name-key-id name-id)))))

(define (clone-name-set-contains-type? [names : CloneNameSet] [name : String]) : bool
  (if (clone-name-set-contains? names name)
    true
    (clone-name-set-contains? names (clone-type-name-base name))))

(define (clone-name-set-contains-type-id?
  [names : CloneNameSet]
  [name-id : i64]) : bool
  (let
    [key-id : i64 (clone-name-key-id name-id)]
    (if (clone-name-set-contains-id? names key-id)
      true
      (if (ci.intern-qualified? name-id)
        (clone-name-set-contains-id?
          names
          (ci.intern-qualified-base-id name-id))
        false))))

(define (clone-name-list-cons-id [key-id : i64] [rest : CloneNameList]) : CloneNameList
  (CloneNameList.ConsId key-id (box rest)))

(define (clone-name-list-cons-existing [name : String] [rest : CloneNameList]) : CloneNameList
  (let
    [key-id : i64 (clone-existing-name-key-id name)]
    (if (< key-id 0)
      rest
      (clone-name-list-cons-id key-id rest))))

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
          [(CloneNameList.ConsId head rest)
            (if (= head key-id)
              (set! found true)
              (set! cur (box-get rest)))]
          [(CloneNameList.Cons head rest)
            (if (= (clone-existing-name-key-id head) key-id)
              (set! found true)
              (set! cur (box-get rest)))]))
      found)))

(define (clone-name-list-contains? [names : CloneNameList] [name : String]) : bool
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
          [(CloneNameList.ConsId head rest)
            (if (string.eq (clone-name-key-string head) name)
              (set! found true)
              (set! cur (box-get rest)))]
          [(CloneNameList.Cons head rest)
            (if (string.eq head name)
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
    (and
      (not (clone-name-set-contains-id? one 2))
      (clone-name-set-contains-id? one 1)
      (= (clone-name-set-len dupe) 1)
      (= (clone-name-set-len grown) 11)
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
      (clone-name-set-contains-canonical-id? names module-id name)]
    [(AstType.Enum name)
      (clone-name-set-contains-resolved-nominal-id? names module-id name)]
    [(AstType.Struct name)
      (clone-name-set-contains-resolved-nominal-id? names module-id name)]
    [_ false]))

(define (clone-field-type-able?
  [pools : AstNodePoolContext]
  [ty : AstType]
  [names : CloneNameSet]
  [module : String]) : bool
  (let
    [module-id : i64
      (if (string.eq module "")
        (clone-root-module-id)
        (match (ci.intern-lookup module)
          [(InternLookupFound found-id) found-id]
          [(InternLookupMissing) (clone-root-module-id)]))]
    (clone-field-type-able-id? pools ty names module-id)))

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
              [(AstDecl.DefEnum name _ variants)
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
              [(AstDecl.DefStruct name _ _ fields)
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
              [(AstDecl.DefEnum name _ _)
                (set!
                  out
                  (clone-name-set-insert-id
                    out
                    (clone-name-key-id-in-module current-module-id name)))]
              [(AstDecl.DefStruct name _ _ _)
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
        (clone-name-set-with-capacity (clone-name-set-capacity names)))]
    (if (= (clone-name-set-len next) (clone-name-set-len names))
      next
      (clone-fixpoint pools decls next))))

;; --- code generation ---------------------------------------------------------
;; `(clone <expr>)`
(define (clone-call-expr [pools : AstNodePoolContext] [inner : i64]) : i64
  (ast-expr-call-with-pools
    pools
    (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-clone))
    (ast-expr-cons inner (ast-expr-list-new))))

;; Binder name for the i-th field of a variant: tlc0, tlc1, ...
(define (clone-binder-name [i : i64]) : String
  (string.append "tlc" (string.int->string i)))

(defstruct CloneVariantBinders
  (patterns AstPatternList)
  (ctor-args AstExprList))

;; Allocate each generated binder once, then use that id in both the pattern
;; and the reconstructed constructor expression.
(define (clone-variant-binders
  [pools : AstNodePoolContext]
  [count : i64]
  [i : i64]) : CloneVariantBinders
  (if (>= i count)
    (CloneVariantBinders (ast-pattern-list-new) (ast-expr-list-new))
    (let
      [name-id : i64 (ci.intern-generated-name (clone-binder-name i))]
      [rest : CloneVariantBinders (clone-variant-binders pools count (+ i 1))]
      (CloneVariantBinders
        (ast-pattern-cons
          (ast-pat-binding-id name-id)
          (struct-get rest patterns))
        (ast-expr-cons
          (clone-call-expr pools (clone-expr-push pools (AstExpr.Var name-id)))
          (struct-get rest ctor-args))))))

(define (clone-type-list-len [types : AstTypeList]) : i64
  (ast-type-list-len (& types)))

;; One match arm: [(V f...) (V (clone f)...)], or [(V) (V)] for nullary variants.
(define (clone-variant-arm
  [pools : AstNodePoolContext]
  [variant : AstVariantDef]) : AstMatchArm
  (match variant
    [(AstVariantDef.Def vname field-types _)
      (let
        [count : i64 (clone-type-list-len field-types)]
        [binders : CloneVariantBinders (clone-variant-binders pools count 0)]
        (ast-match-arm
          (ast-pat-variant-id vname (struct-get binders patterns))
          (ast-expr-call-with-pools
            pools
            (clone-expr-push pools (AstExpr.Var vname))
            (struct-get binders ctor-args))))]))

(define (clone-variant-arms
  [pools : AstNodePoolContext]
  [variants : AstVariantDefList]) : AstMatchArmList
  (clone-variant-arms-at pools (& variants) 0))

(define (clone-variant-arms-at
  [pools : AstNodePoolContext]
  [variants : (& variants AstVariantDefList)]
  [index : i64]) : AstMatchArmList
  (if (>= index (ast-variant-def-list-len variants))
    (ast-match-arm-list-new)
    (ast-match-arm-cons
      (clone-variant-arm
        pools
        (ast-variant-def-list-get variants index (ast-variant-def-fallback)))
      (clone-variant-arms-at pools variants (+ index 1)))))

;; Struct constructor args: (clone (struct-get x f0)) (clone (struct-get x f1)) ...
(define (clone-struct-ctor-args
  [pools : AstNodePoolContext]
  [fields : AstFieldDefList]) : AstExprList
  (clone-struct-ctor-args-at pools (& fields) 0))

(define (clone-struct-ctor-args-at
  [pools : AstNodePoolContext]
  [fields : (& fields AstFieldDefList)]
  [index : i64]) : AstExprList
  (if (>= index (ast-field-def-list-len fields))
    (ast-expr-list-new)
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def fname _ _)
        (ast-expr-cons
          (clone-call-expr
            pools
            (ast-expr-struct-get-id-with-pools
              pools
              (clone-expr-push
                pools
                (AstExpr.Var cbi.compiler-builtin-id-fix-x))
              fname))
          (clone-struct-ctor-args-at pools fields (+ index 1)))])))

;; Build the `(define (clone$Name [x : Name]) : Name <body>)` declaration.
(define (clone-make-helper-decl
  [type-name-id : i64]
  [helper-name-id : i64]
  [body : i64]) : AstDecl
  (ast-decl-def-fn-id
    helper-name-id
    (ast-param-cons
      (ast-param-id
        cbi.compiler-builtin-id-fix-x
        (AstType.Var type-name-id)
        false)
      (ast-param-list-new))
    (AstType.Var type-name-id)
    body))

;; --- tail-recursive clone for list-like types --------------------------------
;;
;; The naive match-reconstruct clone recurses once per cons cell:
;;   [(Cons h t) (Cons (clone h) (clone t))]  -- (clone t) is NOT in tail
;; position, so a list of N cells costs N stack frames. The compiler's IR lists
;; (instr/block/function lists) reach tens of thousands of cells, which overflows
;; the default stack when a self-hosted compiler clones one during an arena
;; escape. For list-shaped enums we instead emit an O(1)-frame, tail-recursive
;; clone: accumulate the cloned elements into a reversed list, then reverse it
;; back into order. Element clones stay bounded-depth via `(clone h)`.
(defenum CloneListShape
  (NotList)
  (IsList i64 i64 bool))

; nil-ctor name, cons-ctor name
(define (clone-variant-field-count [v : AstVariantDef]) : i64
  (match v
    [(AstVariantDef.Def _ field-types _) (clone-type-list-len field-types)]))

(define (clone-variant-name-id [v : AstVariantDef]) : i64
  (match v
    [(AstVariantDef.Def name _ _) name]))

(define (clone-name-base-id [name-id : i64]) : i64
  (if (and
    (>= name-id 0)
    (< name-id (ci.intern-capacity))
    (ci.intern-qualified? name-id))
    (ci.intern-qualified-base-id name-id)
    name-id))

(define (clone-type-is-name-id? [ty : AstType] [name-id : i64]) : bool
  (match ty
    [(AstType.Var n) (= (clone-name-base-id n) (clone-name-base-id name-id))]
    [(AstType.Enum n) (= (clone-name-base-id n) (clone-name-base-id name-id))]
    [_ false]))

;; True iff `tail` is the enum itself, either directly or through a Box tail.
(define (clone-tail-is-self?
  [pools : AstNodePoolContext]
  [tail : AstType]
  [self-name-id : i64]) : bool
  (match tail
    [(AstType.Box inner)
      (clone-type-is-name-id? (clone-type-get pools inner) self-name-id)]
    [_ (clone-type-is-name-id? tail self-name-id)]))

(define (clone-tail-is-boxed-self?
  [pools : AstNodePoolContext]
  [tail : AstType]
  [self-name-id : i64]) : bool
  (match tail
    [(AstType.Box inner)
      (clone-type-is-name-id? (clone-type-get pools inner) self-name-id)]
    [_ false]))

;; True iff `v` is a two-field variant whose SECOND field is the enum itself
;; (the `(Cons element Self)` or `(Cons element (Box Self))` shape).
(define (clone-variant-cons-tail-self?
  [pools : AstNodePoolContext]
  [v : AstVariantDef]
  [self-name-id : i64]) : bool
  (match v
    [(AstVariantDef.Def _ field-types _)
      (and
        (= (ast-type-list-len (& field-types)) 2)
        (clone-tail-is-self?
          pools
          (clone-type-get
            pools
            (ast-type-list-get (& field-types) 1 (ast-type-id-fallback)))
          self-name-id))]))

(define (clone-variant-cons-tail-boxed?
  [pools : AstNodePoolContext]
  [v : AstVariantDef]
  [self-name-id : i64]) : bool
  (match v
    [(AstVariantDef.Def _ field-types _)
      (and
        (= (ast-type-list-len (& field-types)) 2)
        (clone-tail-is-boxed-self?
          pools
          (clone-type-get
            pools
            (ast-type-list-get (& field-types) 1 (ast-type-id-fallback)))
          self-name-id))]))

;; If (nil-v, cons-v) form a Nil/Cons pair, return the list shape; else NotList.
(define (clone-list-shape-try
  [pools : AstNodePoolContext]
  [nil-v : AstVariantDef]
  [cons-v : AstVariantDef]
  [self-name-id : i64]) : CloneListShape
  (if (= (clone-variant-field-count nil-v) 0)
    (if (clone-variant-cons-tail-self? pools cons-v self-name-id)
      (CloneListShape.IsList
        (clone-variant-name-id nil-v)
        (clone-variant-name-id cons-v)
        (clone-variant-cons-tail-boxed? pools cons-v self-name-id))
      (CloneListShape.NotList))
    (CloneListShape.NotList)))

;; A list-shaped enum is exactly two variants: one nullary (Nil) and one
;; `(Cons element Self)` or `(Cons element (Box Self))`, in either source order.
(define (clone-list-shape
  [pools : AstNodePoolContext]
  [variants : AstVariantDefList]
  [self-name-id : i64]) : CloneListShape
  (if (= (ast-variant-def-list-len (& variants)) 2)
    (let
      [v1 : AstVariantDef
        (ast-variant-def-list-get (& variants) 0 (ast-variant-def-fallback))]
      [v2 : AstVariantDef
        (ast-variant-def-list-get (& variants) 1 (ast-variant-def-fallback))]
      (match (clone-list-shape-try pools v1 v2 self-name-id)
        [(CloneListShape.IsList n c boxed) (CloneListShape.IsList n c boxed)]
        [(CloneListShape.NotList)
          (clone-list-shape-try pools v2 v1 self-name-id)]))
    (CloneListShape.NotList)))

(define (clone-list-acc-name [type-name : String]) : String
  (string.append (clone-local-helper-name type-name) "$acc"))

(define (clone-list-rev-name [type-name : String]) : String
  (string.append (clone-local-helper-name type-name) "$rev"))

;; `(Nil)` - a nullary constructor is a zero-arg call, as in clone-variant-arm.
(define (clone-nil-expr [pools : AstNodePoolContext] [nil-ctor-id : i64]) : i64
  (ast-expr-call-with-pools
    pools
    (clone-expr-push pools (AstExpr.Var nil-ctor-id))
    (ast-expr-list-new)))

(define (clone-list-tail-next-expr
  [pools : AstNodePoolContext]
  [boxed-tail : bool]) : i64
  (if boxed-tail
    (ast-expr-box-get-with-pools
      pools
      (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-t)))
    (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-t))))

(define (clone-list-tail-acc-expr
  [pools : AstNodePoolContext]
  [boxed-tail : bool]) : i64
  (if boxed-tail
    (ast-expr-box-with-pools
      pools
      (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-acc)))
    (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-acc))))

;; A two-parameter `(define (fn [x : T] [acc : T]) : T body)`.
(define (clone-make-list-fn
  [fn-name-id : i64]
  [type-name-id : i64]
  [body : i64]) : AstDecl
  (ast-decl-def-fn-id
    fn-name-id
    (ast-param-cons
      (ast-param-id
        cbi.compiler-builtin-id-fix-x
        (AstType.Var type-name-id)
        false)
      (ast-param-cons
        (ast-param-id
          cbi.compiler-builtin-id-fix-acc
          (AstType.Var type-name-id)
          false)
        (ast-param-list-new)))
    (AstType.Var type-name-id)
    body))

;; The `(Cons-pattern h t)` -> recursive-tail-call match arm shared by acc/rev.
;; `head-expr` is the head placed into the rebuilt cons (cloned for acc, bare
;; for rev). `fn-name` is the function to tail-call.
(define (clone-list-step-arm
  [pools : AstNodePoolContext]
  [fn-name-id : i64]
  [cons-ctor-id : i64]
  [boxed-tail : bool]
  [head-expr : i64]) : AstMatchArm
  (ast-match-arm
    (ast-pat-variant-id
      cons-ctor-id
      (ast-pattern-cons
        (ast-pat-binding-id cbi.compiler-builtin-id-fix-h)
        (ast-pattern-cons
          (ast-pat-binding-id cbi.compiler-builtin-id-fix-t)
          (ast-pattern-list-new))))
    (ast-expr-call-with-pools
      pools
      (clone-expr-push pools (AstExpr.Var fn-name-id))
      (ast-expr-cons
        (clone-list-tail-next-expr pools boxed-tail)
        (ast-expr-cons
          (ast-expr-call-with-pools
            pools
            (clone-expr-push pools (AstExpr.Var cons-ctor-id))
            (ast-expr-cons
              head-expr
              (ast-expr-cons
                (clone-list-tail-acc-expr pools boxed-tail)
                (ast-expr-list-new))))
          (ast-expr-list-new))))))

;; (match x [(Nil) acc] [(Cons h t) (fn t (Cons head-expr acc))])
(define (clone-list-fold-body
  [pools : AstNodePoolContext]
  [fn-name-id : i64]
  [nil-ctor-id : i64]
  [cons-ctor-id : i64]
  [boxed-tail : bool]
  [head-expr : i64]) : i64
  (ast-expr-match-with-pools
    pools
    (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-x))
    (ast-match-arm-cons
      (ast-match-arm
        (ast-pat-variant-id nil-ctor-id (ast-pattern-list-new))
        (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-acc)))
      (ast-match-arm-cons
        (clone-list-step-arm pools fn-name-id cons-ctor-id boxed-tail head-expr)
        (ast-match-arm-list-new)))))

;; clone$L$acc: tail-recursively clone each element into a reversed accumulator.
(define (clone-list-acc-decl
  [pools : AstNodePoolContext]
  [type-name-id : i64]
  [fn-name-id : i64]
  [nil-ctor-id : i64]
  [cons-ctor-id : i64]
  [boxed-tail : bool]) : AstDecl
  (clone-make-list-fn
    fn-name-id
    type-name-id
    (clone-list-fold-body
      pools
      fn-name-id
      nil-ctor-id
      cons-ctor-id
      boxed-tail
      (clone-call-expr
        pools
        (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-h))))))

;; clone$L$rev: tail-recursively reverse (no cloning) to restore source order.
(define (clone-list-rev-decl
  [pools : AstNodePoolContext]
  [type-name-id : i64]
  [fn-name-id : i64]
  [nil-ctor-id : i64]
  [cons-ctor-id : i64]
  [boxed-tail : bool]) : AstDecl
  (clone-make-list-fn
    fn-name-id
    type-name-id
    (clone-list-fold-body
      pools
      fn-name-id
      nil-ctor-id
      cons-ctor-id
      boxed-tail
      (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-h)))))

;; clone$L: reverse(acc(x, Nil), Nil) - both folds run in O(1) stack frames.
(define (clone-list-entry-decl
  [pools : AstNodePoolContext]
  [type-name-id : i64]
  [entry-name-id : i64]
  [acc-name-id : i64]
  [rev-name-id : i64]
  [nil-ctor-id : i64]) : AstDecl
  (clone-make-helper-decl
    type-name-id
    entry-name-id
    (ast-expr-call-with-pools
      pools
      (clone-expr-push pools (AstExpr.Var rev-name-id))
      (ast-expr-cons
        (ast-expr-call-with-pools
          pools
          (clone-expr-push pools (AstExpr.Var acc-name-id))
          (ast-expr-cons
            (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-x))
            (ast-expr-cons
              (clone-nil-expr pools nil-ctor-id)
              (ast-expr-list-new))))
        (ast-expr-cons (clone-nil-expr pools nil-ctor-id) (ast-expr-list-new))))))

;; Emit the clone helper(s) for one clone-able enum: three tail-recursive
;; functions for a list shape, otherwise the single naive match-reconstruct.
(define (clone-emit-enum-clone
  [pools : AstNodePoolContext]
  [type-name-id : i64]
  [type-key-id : i64]
  [helper-name-id : i64]
  [variants : AstVariantDefList]
  [acc : AstDeclList]) : AstDeclList
  (match (clone-list-shape pools variants type-name-id)
    [(CloneListShape.IsList nil-ctor-id cons-ctor-id boxed-tail)
      (let
        [type-name : String (ci.intern-str type-name-id)]
        [acc-name-id : i64
          (ci.intern-generated-name (clone-list-acc-name type-name))]
        [rev-name-id : i64
          (ci.intern-generated-name (clone-list-rev-name type-name))]
        [qualified-nil-id : i64
          (clone-list-variant-reference-id type-name-id nil-ctor-id)]
        [qualified-cons-id : i64
          (clone-list-variant-reference-id type-name-id cons-ctor-id)]
        (begin
          (clone_id_map.insert
            (&mut clone-helper-acc-name-ids)
            type-key-id
            acc-name-id)
          (clone_id_map.insert
            (&mut clone-helper-rev-name-ids)
            type-key-id
            rev-name-id)
          (ast-decl-list-prepend-builder
            (clone-list-entry-decl
              pools
              type-name-id
              helper-name-id
              acc-name-id
              rev-name-id
              qualified-nil-id)
            (ast-decl-list-prepend-builder
              (clone-list-acc-decl
                pools
                type-name-id
                acc-name-id
                qualified-nil-id
                qualified-cons-id
                boxed-tail)
              (ast-decl-list-prepend-builder
                (clone-list-rev-decl
                  pools
                  type-name-id
                  rev-name-id
                  qualified-nil-id
                  qualified-cons-id
                  boxed-tail)
                acc)))))]
    [(CloneListShape.NotList)
      (ast-decl-list-prepend-builder
        (clone-make-helper-decl
          type-name-id
          helper-name-id
          (ast-expr-match-with-pools
            pools
            (clone-expr-push pools (AstExpr.Var cbi.compiler-builtin-id-fix-x))
            (clone-variant-arms pools variants)))
        acc)]))

(cfg
  test
  (define (clone-test-id-name? [name : i64] [want : String]) : bool
    (string.eq (intern-str name) want)))

(cfg
  test
  (define (clone-test-pattern-list-name-count
    [patterns : AstPatternList]
    [want : String]) : i64
    (clone-test-pattern-list-name-count-at (& patterns) want 0)))

(cfg
  test
  (define (clone-test-pattern-list-name-count-at
    [patterns : (& patterns AstPatternList)]
    [want : String]
    [index : i64]) : i64
    (if (>= index (ast-pattern-list-len patterns))
      0
      (+
        (clone-test-pattern-name-count
          (ast-pattern-list-get patterns index (ast-pattern-fallback))
          want)
        (clone-test-pattern-list-name-count-at patterns want (+ index 1))))))

(cfg
  test
  (define (clone-test-pattern-name-count [pattern : AstPattern] [want : String]) : i64
    (match pattern
      [(AstPattern.Tuple items)
        (clone-test-pattern-list-name-count (box-get items) want)]
      [(AstPattern.Variant name items)
        (+
          (if (clone-test-id-name? name want)
            1
            0)
          (clone-test-pattern-list-name-count (box-get items) want))]
      [_ 0])))

(cfg
  test
  (define (clone-test-expr-list-name-count
    [pools : AstNodePoolContext]
    [exprs : AstExprList]
    [want : String]) : i64
    (clone-test-expr-list-name-count-at pools (& exprs) want 0)))

(cfg
  test
  (define (clone-test-expr-list-name-count-at
    [pools : AstNodePoolContext]
    [exprs : (& exprs AstExprList)]
    [want : String]
    [index : i64]) : i64
    (if (>= index (ast-expr-list-len exprs))
      0
      (+
        (clone-test-expr-name-count
          pools
          (ast-expr-list-get exprs index 0)
          want)
        (clone-test-expr-list-name-count-at pools exprs want (+ index 1))))))

(cfg
  test
  (define (clone-test-match-arm-list-name-count
    [pools : AstNodePoolContext]
    [arms : AstMatchArmList]
    [want : String]) : i64
    (clone-test-match-arm-list-name-count-at pools (& arms) want 0)))

(cfg
  test
  (define (clone-test-match-arm-list-name-count-at
    [pools : AstNodePoolContext]
    [arms : (& arms AstMatchArmList)]
    [want : String]
    [index : i64]) : i64
    (if (>= index (ast-match-arm-list-len arms))
      0
      (match (ast-match-arm-list-get arms index (ast-match-arm-fallback))
        [(AstMatchArm.Arm pattern body)
          (+
            (clone-test-pattern-name-count pattern want)
            (+
              (clone-test-expr-name-count pools body want)
              (clone-test-match-arm-list-name-count-at
                pools
                arms
                want
                (+ index 1))))]))))

(cfg
  test
  (define (clone-test-expr-name-count
    [pools : AstNodePoolContext]
    [expr-id : i64]
    [want : String]) : i64
    (match (ast-node-pool-context-expr-get pools expr-id)
      [(AstExpr.Var name)
        (if (clone-test-id-name? name want)
          1
          0)]
      [(AstExpr.Call callee args)
        (+
          (clone-test-expr-name-count pools callee want)
          (clone-test-expr-list-name-count pools args want))]
      [(AstExpr.Match match-box)
        (match (box-get match-box)
          [(AstMatch.Match scrutinee arms)
            (+
              (clone-test-expr-name-count pools scrutinee want)
              (clone-test-match-arm-list-name-count pools arms want))])]
      [(AstExpr.Box inner) (clone-test-expr-name-count pools inner want)]
      [(AstExpr.BoxGet inner) (clone-test-expr-name-count pools inner want)]
      [_ 0])))

(cfg
  test
  (define (clone-test-decl-list-name-count
    [pools : AstNodePoolContext]
    [decls : AstDeclList]
    [want : String]) : i64
    (match (ast-decl-list-step decls)
      [(AstDeclListStep.Nil) 0]
      [(AstDeclListStep.Cons decl rest)
        (+
          (match decl
            [(AstDecl.DefFn _ _ _ body _)
              (clone-test-expr-name-count pools body want)]
            [_ 0])
          (clone-test-decl-list-name-count pools rest want))])))

(cfg
  test
  (define (clone-test-short-list-variants) : AstVariantDefList
    (let
      [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
      [tail-ty : AstType
        (ast-ty-box-with-pools
          pools
          (AstType.Var cbi.compiler-builtin-id-fix-CloneShortList))]
      [cons-fields : AstTypeList
        (ast-type-cons-with-pools
          pools
          (AstType.I64)
          (ast-type-cons-with-pools pools tail-ty (ast-type-list-new)))]
      (ast-variant-def-cons
        (AstVariantDef.Def
          cbi.compiler-builtin-id-fix-Nil
          (ast-type-list-new)
          (ast-variant-payload-cleanup-list-new))
        (ast-variant-def-cons
          (AstVariantDef.Def
            cbi.compiler-builtin-id-fix-Cons
            cons-fields
            (ast-variant-payload-cleanup-list-new))
          (ast-variant-def-list-new))))))

(cfg
  test
  (define (clone-qualified-short-list-generation-ok?) : bool
    (let
      [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
      [decls : AstDeclList
        (clone-emit-enum-clone
          pools
          cbi.compiler-builtin-id-fix-CloneShortList
          (clone-name-key-id cbi.compiler-builtin-id-fix-CloneShortList)
          (ci.intern-generated-name "clone$CloneShortList")
          (clone-test-short-list-variants)
          (ast-decl-list-new))]
      (and
        (> (clone-test-decl-list-name-count pools decls "CloneShortList.Nil") 0)
        (>
          (clone-test-decl-list-name-count pools decls "CloneShortList.Cons")
          0)
        (= (clone-test-decl-list-name-count pools decls "Nil") 0)
        (= (clone-test-decl-list-name-count pools decls "Cons") 0)
        (string.eq
          (clone-list-variant-reference-name "SelfNamed" "SelfNamed")
          "SelfNamed")))))

;; Generate clone$ helpers for every clone-able enum/struct, prepended in order.
(define (clone-prepend-generated-decls-in-module
  [module-id : i64]
  [generated : AstDeclList]
  [acc : AstDeclList]) : AstDeclList
  (if (clone-module-id-root? module-id)
    (clone-decl-list-append generated acc)
    (ast-decl-list-prepend-builder
      (ast-decl-module-id module-id)
      (clone-decl-list-append generated acc))))

(define (clone-generate-decls-in-module
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [acc : AstDeclList]
  [module-id : i64]) : AstDeclList
  (let
    [cur : AstDeclList decls]
    [out : AstDeclList acc]
    [current-module-id : i64 module-id]
    (begin
      (while (not (ast-decl-list-empty? (& cur)))
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
                [(AstDecl.DefEnum name _ variants)
                  (let
                    [name-key-id : i64
                      (clone-name-key-id-in-module current-module-id name)]
                    (begin
                      (if (clone-name-set-contains-id? able name-key-id)
                        (let
                          [helper-name-id : i64
                            (ci.intern-generated-name
                              (clone-local-helper-name (ci.intern-str name)))]
                          (begin
                            (clone-helper-name-id-bind!
                              name-key-id
                              helper-name-id)
                            (set!
                              out
                              (clone-prepend-generated-decls-in-module
                                current-module-id
                                (clone-emit-enum-clone
                                  pools
                                  name
                                  name-key-id
                                  helper-name-id
                                  variants
                                  (ast-decl-list-new))
                                out))))
                        unit)
                      (set! cur rest)))]
                [(AstDecl.DefStruct name _ _ fields)
                  (let
                    [name-key-id : i64
                      (clone-name-key-id-in-module current-module-id name)]
                    (begin
                      (if (clone-name-set-contains-id? able name-key-id)
                        (let
                          [helper-name-id : i64
                            (ci.intern-generated-name
                              (clone-local-helper-name (ci.intern-str name)))]
                          (begin
                            (clone-helper-name-id-bind!
                              name-key-id
                              helper-name-id)
                            (set!
                              out
                              (clone-prepend-generated-decls-in-module
                                current-module-id
                                (ast-decl-list-prepend-builder
                                  (clone-make-helper-decl
                                    name
                                    helper-name-id
                                    (ast-expr-call-with-pools
                                      pools
                                      (clone-expr-push pools (AstExpr.Var name))
                                      (clone-struct-ctor-args pools fields)))
                                  (ast-decl-list-new))
                                out))))
                        unit)
                      (set! cur rest)))]
                [_ (set! cur rest)]))]))
      out)))

(define (clone-generate-decls
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [acc : AstDeclList]) : AstDeclList
  (clone-generate-decls-in-module pools decls able acc (clone-root-module-id)))

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
                [(AstDecl.DefEnum decl-name _ variants)
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
                [(AstDecl.DefStruct decl-name _ _ fields)
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
        (clone-name-key-id-in-module module-id name))]
    [(AstType.Enum name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-name-key-id-in-module module-id name))]
    [(AstType.Struct name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-name-key-id-in-module module-id name))]
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
          [(CloneNameList.ConsId name-key-id rest)
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
                (set! cur (box-get rest))))]
          [(CloneNameList.Cons name rest)
            (let
              [name-key-id : i64 (clone-existing-name-key-id name)]
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
          [(CloneNameList.ConsId name-key-id rest)
            (begin
              (set! out (clone-name-set-insert-id out name-key-id))
              (set! cur (box-get rest)))]
          [(CloneNameList.Cons name rest)
            (begin
              (set!
                out
                (clone-name-set-insert-id out (clone-existing-name-key-id name)))
              (set! cur (box-get rest)))]))
      out)))

;; Append the generated clone$ helpers AFTER the program's decls, so the real
;; declarations keep their source paths (the generated helpers, being last, get
;; the empty path on lookup). Top-level functions are mutually visible, so the
;; helpers can forward-reference the type constructors and each other.
(define (clone-augment-decls-with-pools
  [pools : AstNodePoolContext]
  [decls : AstDeclList]) : AstDeclList
  (let
    [able : CloneNameSet
      (clone-fixpoint
        pools
        decls
        (clone-all-type-names decls (clone-name-set-empty)))]
    (clone-decl-list-append
      decls
      (clone-generate-decls pools decls able (ast-decl-list-new)))))

(define (clone-augment-decls-with-roots-and-pools
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [roots : CloneNameList]) : AstDeclList
  (let
    [able : CloneNameSet
      (clone-fixpoint
        pools
        decls
        (clone-all-type-names decls (clone-name-set-empty)))]
    (clone-augment-decls-with-roots-and-able-and-pools pools decls able roots)))

;; Typechecking already computes the whole-program cloneability fixpoint for
;; `(clone ...)` validation. The lowering pipeline can pass that exact set here
;; when it synthesizes helpers after typecheck instead of rebuilding the same
;; type graph during clone augmentation.
(define (clone-augment-decls-with-roots-and-able-and-pools
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]) : AstDeclList
  (let
    [expanded : CloneNameList (clone-root-expand pools decls able roots roots)]
    (clone-decl-list-append
      decls
      (clone-generate-decls
        pools
        decls
        (clone-name-list-to-set expanded (clone-name-set-empty))
        (ast-decl-list-new)))))

(define (clone-augment-decls [decls : AstDeclList]) : AstDeclList
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [out : AstDeclList (clone-augment-decls-with-pools pools decls)]
    (begin
      (ast-node-pool-context-install! pools)
      out)))

(define (clone-augment-decls-with-roots
  [decls : AstDeclList]
  [roots : CloneNameList]) : AstDeclList
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [out : AstDeclList
      (clone-augment-decls-with-roots-and-pools pools decls roots)]
    (begin
      (ast-node-pool-context-install! pools)
      out)))

(define (clone-augment-program-with-pools
  [pools : AstNodePoolContext]
  [program : AstProgram]) : AstProgram
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-program (clone-augment-decls-with-pools pools decls)))]))

(define (clone-augment-program-with-roots-and-pools
  [pools : AstNodePoolContext]
  [program : AstProgram]
  [roots : CloneNameList]) : AstProgram
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-program
          (clone-augment-decls-with-roots-and-pools pools decls roots)))]))

(define (clone-augment-program-with-roots-and-able-and-pools
  [pools : AstNodePoolContext]
  [program : AstProgram]
  [able : CloneNameSet]
  [roots : CloneNameList]) : AstProgram
  (match program
    [(AstProgram.Program decls-box)
      (let
        [decls : AstDeclList (box-get decls-box)]
        (ast-program
          (clone-augment-decls-with-roots-and-able-and-pools
            pools
            decls
            able
            roots)))]))

(define (clone-augment-program-with-roots-from-pools
  [source-pools : AstNodePoolContext]
  [dest-pools : AstNodePoolContext]
  [program : AstProgram]
  [roots : CloneNameList]) : AstProgramCompaction
  (match program
    [(AstProgram.Program source-decls-box)
      (let
        [source-decls : AstDeclList (box-get source-decls-box)]
        [able : CloneNameSet
          (clone-fixpoint
            source-pools
            source-decls
            (clone-all-type-names source-decls (clone-name-set-empty)))]
        [expanded : CloneNameList
          (clone-root-expand source-pools source-decls able roots roots)]
        [compacted : AstProgramCompaction
          (ast-program-compact-with-pools source-pools dest-pools program)]
        (match compacted
          [(AstProgramCompaction copied-program _)
            (match copied-program
              [(AstProgram.Program copied-decls-box)
                (let
                  [copied-decls : AstDeclList (box-get copied-decls-box)]
                  [prev-arena : i64 (arena.tl_arena_current)]
                  [result : AstProgramCompaction
                    (begin
                      (unsafe
                        (arena.tl_arena_set
                          (ast-node-pool-context-base-arena dest-pools)))
                      (let
                        [clone-decls : AstDeclList
                          (clone-generate-decls
                            dest-pools
                            copied-decls
                            (clone-name-list-to-set
                              expanded
                              (clone-name-set-empty))
                            (ast-decl-list-new))]
                        [checked-decls : AstDeclList
                          (clone-decl-list-append copied-decls clone-decls)]
                        [checked-program : AstProgram
                          (ast-program checked-decls)]
                        [out : AstProgramCompaction
                          (begin
                            (ast-node-pool-context-sync-base-arena!
                              dest-pools
                              (arena.tl_arena_current))
                            (AstProgramCompaction
                              checked-program
                              (ast-node-pool-context-snapshot dest-pools)))]
                        (begin
                          (unsafe
                            (arena.tl_arena_set prev-arena))
                          out)))]
                  result)])]))]))

(define (clone-augment-program [program : AstProgram]) : AstProgram
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [out : AstProgram (clone-augment-program-with-pools pools program)]
    (begin
      (ast-node-pool-context-install! pools)
      out)))

(define (clone-augment-program-with-roots
  [program : AstProgram]
  [roots : CloneNameList]) : AstProgram
  (let
    [pools : AstNodePoolContext (ast-node-pool-context-capture-active)]
    [out : AstProgram
      (clone-augment-program-with-roots-and-pools pools program roots)]
    (begin
      (ast-node-pool-context-install! pools)
      out)))

(cfg
  test
  (test
    clone-qualified-short-list-variants
    (test.assert-true
      (clone-qualified-short-list-generation-ok?)
      "clone: short list variants should be generated as enum-qualified names")))
