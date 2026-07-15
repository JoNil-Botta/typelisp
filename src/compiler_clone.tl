;; compiler_clone.tl - validate cloneability and discover helper roots.
;;
;; `(clone x)` is the canonical deep-copy and the canonical way to escape an
;; arena. The lowerer dispatches `(clone x)` to `clone$<type-of-x>` for named
;; aggregate types (enums/structs); strings copy their buffer via `substring`
;; and scalars are returned as-is. The compiler retains semantic validation,
;; canonical naming, and reachable nominal-root closure. `stdlib/clone.tl`
;; owns the declaration AST emitted for each root through the typed handoff.
;;
;; tuple, fixed array, dynamic array, Box of a clone-able type, or another
;; clone-able named type. Function, reference, raw-pointer, str, and
;; compile-time-only values are not clone-able. Clone-ability is a
;; least-fixed-point over the type graph.
(import "compiler_ast_types.tl")
(import stdlib.hashmap)
(import (hashmap String i64) as clone_name_map)
(import (hashmap String String) as clone_alias_map)
(import stdlib.string)

(defstruct CloneNameSet
  (map clone_name_map.Map)
  (aliases clone_alias_map.Map))

(defenum CloneNameList
  (Nil)
  (Cons String (Box CloneNameList)))

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

(define (clone-import-alias-key [module : String] [alias : String]) : String
  (string.append (string.append module "/") alias))

(define (clone-type-name-resolve
  [names : CloneNameSet]
  [module : String]
  [name : String]) : String
  (if (>= (clone-type-name-last-slash name) 0)
    name
    (let
      [dot : i64 (clone-type-name-first-dot name)]
      (if (<= dot 0)
        (clone-type-name-canonical module name)
        (let
          [aliases : clone_alias_map.Map (struct-get names aliases)]
          [key : String
            (clone-import-alias-key module (string.substring name 0 dot))]
          (match (clone_alias_map.get-borrowed (& aliases) (& key))
            [(clone_alias_map.LookupFound target)
              (clone-type-name-canonical
                target
                (string.substring
                  name
                  (+ dot 1)
                  (- (string.string-length name) (+ dot 1))))]
            [(clone_alias_map.LookupMissing)
              (clone-type-name-canonical module name)]))))))

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
  (CloneNameSet
    (clone_name_map.with-capacity 8)
    (clone_alias_map.with-capacity 8)))

(define (clone-name-set-for-decls [decls : AstDeclList]) : CloneNameSet
  (let
    [aliases : clone_alias_map.Map (clone_alias_map.with-capacity 64)]
    [current-module : String ""]
    [index : i64 0]
    [count : i64 (ast-decl-list-len (& decls))]
    (begin
      (while (< index count)
        (begin
          (match (ast-decl-unwrapped
            (ast-decl-list-get (& decls) index (ast-decl-fallback)))
            [(AstDecl.Module next-module)
              (set! current-module (intern-str next-module))]
            [(AstDecl.Import
                (AstImportSpec.Spec
                  _
                  _
                  (AstMaybeModuleName.Some target)
                  (AstMaybeImportAlias.Some alias)
                  _))
              (clone_alias_map.insert-ref!
                (&mut aliases)
                (clone-import-alias-key current-module alias)
                target)]
            [_ unit])
          (set! index (+ index 1))))
      (CloneNameSet (clone_name_map.with-capacity 8) aliases))))

;; The fixpoint rebuilds its accepted set on each step over the whole-program
;; type universe; seeding that accumulator at the input set's capacity (it can
;; only shrink relative to the input) avoids the rehash+fill-empty grow chain a
;; capacity-8 seed would walk on every step.
(define (clone-name-set-with-capacity
  [capacity : i64]
  [aliases : clone_alias_map.Map]) : CloneNameSet
  (CloneNameSet (clone_name_map.with-capacity capacity) aliases))

(define (clone-name-set-map [names : CloneNameSet]) : clone_name_map.Map
  (struct-get names map))

(define (clone-name-set-aliases [names : CloneNameSet]) : clone_alias_map.Map
  (struct-get names aliases))

(define (clone-name-set-insert [names : CloneNameSet] [name : String]) : CloneNameSet
  (let
    [map (clone-name-set-map names)]
    (begin
      (clone_name_map.insert-ref! (&mut map) name 1)
      (CloneNameSet map (clone-name-set-aliases names)))))

(define (clone-name-set-contains? [names : CloneNameSet] [name : String]) : bool
  (let
    [map (clone-name-set-map names)]
    (clone_name_map.contains-borrowed? (& map) (& name))))

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

(define (clone-name-set-contains-type? [names : CloneNameSet] [name : String]) : bool
  (if (clone-name-set-contains? names name)
    true
    (clone-name-set-contains? names (clone-type-name-base name))))

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
          [(CloneNameList.Cons head rest)
            (if (string.eq head name)
              (set! found true)
              (set! cur (box-get rest)))]))
      found)))

(define (clone-name-set-len [names : CloneNameSet]) : i64
  (let
    [map (clone-name-set-map names)]
    (clone_name_map.len (& map))))

(define (clone-name-set-capacity [names : CloneNameSet]) : i64
  (let
    [map (clone-name-set-map names)]
    (clone_name_map.capacity (& map))))

(define (clone-name-set-smoke-insert-count [names : CloneNameSet] [count : i64]) : CloneNameSet
  (if (<= count 0)
    names
    (clone-name-set-smoke-insert-count
      (clone-name-set-insert
        names
        (string.append "T" (string.int->string count)))
      (- count 1))))

(define (clone-name-set-smoke-ok?) : bool
  (let
    [empty : CloneNameSet (clone-name-set-empty)]
    [one : CloneNameSet (clone-name-set-insert empty "Alpha")]
    [dupe : CloneNameSet (clone-name-set-insert one "Alpha")]
    [seed-capacity : i64 (clone-name-set-capacity dupe)]
    [grown : CloneNameSet (clone-name-set-smoke-insert-count dupe 10)]
    (and
      (not (clone-name-set-contains? one "Beta"))
      (clone-name-set-contains? one "Alpha")
      (= (clone-name-set-len dupe) 1)
      (= (clone-name-set-len grown) 11)
      (> (clone-name-set-capacity grown) seed-capacity))))

(define (clone-type-get [pools : AstNodePoolContext] [id : i64]) : AstType
  (ast-node-pool-context-type-get pools id))

(define (clone-field-type-able?
  [pools : AstNodePoolContext]
  [ty : AstType]
  [names : CloneNameSet]
  [module : String]) : bool
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
      (clone-field-type-list-able? pools (box-get elems) names module)]
    [(AstType.Array elem _)
      (clone-field-type-able? pools (clone-type-get pools elem) names module)]
    [(AstType.DynArray elem)
      (clone-field-type-able? pools (clone-type-get pools elem) names module)]
    [(AstType.Box elem)
      (clone-field-type-able? pools (clone-type-get pools elem) names module)]
    [(AstType.Region _ inner)
      (clone-field-type-able? pools (clone-type-get pools inner) names module)]
    [(AstType.Var name)
      (clone-name-set-contains?
        names
        (clone-type-name-resolve names module (intern-str name)))]
    [(AstType.Enum name)
      (clone-name-set-contains-resolved-nominal? names module (intern-str name))]
    [(AstType.Struct name)
      (clone-name-set-contains-resolved-nominal? names module (intern-str name))]
    [_ false]))

(define (clone-field-type-list-able?
  [pools : AstNodePoolContext]
  [types : AstTypeList]
  [names : CloneNameSet]
  [module : String]) : bool
  (clone-field-type-list-able-at pools (& types) names module 0))

(define (clone-field-type-list-able-at
  [pools : AstNodePoolContext]
  [types : (& types AstTypeList)]
  [names : CloneNameSet]
  [module : String]
  [index : i64]) : bool
  (if (>= index (ast-type-list-len types))
    true
    (if (clone-field-type-able?
      pools
      (clone-type-get
        pools
        (ast-type-list-get types index (ast-type-id-fallback)))
      names
      module)
      (clone-field-type-list-able-at pools types names module (+ index 1))
      false)))

(define (clone-variant-list-able?
  [pools : AstNodePoolContext]
  [variants : AstVariantDefList]
  [names : CloneNameSet]
  [module : String]) : bool
  (clone-variant-list-able-at pools (& variants) names module 0))

(define (clone-variant-list-able-at
  [pools : AstNodePoolContext]
  [variants : (& variants AstVariantDefList)]
  [names : CloneNameSet]
  [module : String]
  [index : i64]) : bool
  (if (>= index (ast-variant-def-list-len variants))
    true
    (match (ast-variant-def-list-get variants index (ast-variant-def-fallback))
      [(AstVariantDef.Def _ field-types _)
        (if (clone-field-type-list-able? pools field-types names module)
          (clone-variant-list-able-at pools variants names module (+ index 1))
          false)])))

(define (clone-struct-fields-able?
  [pools : AstNodePoolContext]
  [fields : AstFieldDefList]
  [names : CloneNameSet]
  [module : String]) : bool
  (clone-struct-fields-able-at pools (& fields) names module 0))

(define (clone-struct-fields-able-at
  [pools : AstNodePoolContext]
  [fields : (& fields AstFieldDefList)]
  [names : CloneNameSet]
  [module : String]
  [index : i64]) : bool
  (if (>= index (ast-field-def-list-len fields))
    true
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ ty _)
        (if (clone-field-type-able? pools ty names module)
          (clone-struct-fields-able-at pools fields names module (+ index 1))
          false)])))

;; One fixpoint step: keep only names whose declaration's fields are all
;; clone-able under the current `names` set. Repeats until the set stops
;; shrinking (monotone decreasing, so it terminates).
(define (clone-fixpoint-step-in-module
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [names : CloneNameSet]
  [acc : CloneNameSet]
  [module : String]) : CloneNameSet
  (let
    [out : CloneNameSet acc]
    [current-module : String module]
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
                (set! current-module (intern-str next-module))]
              [(AstDecl.DefEnum name _ variants)
                (if (clone-variant-list-able?
                  pools
                  variants
                  names
                  current-module)
                  (set!
                    out
                    (clone-name-set-insert
                      out
                      (clone-type-name-canonical
                        current-module
                        (intern-str name))))
                  unit)]
              [(AstDecl.DefStruct name _ _ fields)
                (if (clone-struct-fields-able?
                  pools
                  fields
                  names
                  current-module)
                  (set!
                    out
                    (clone-name-set-insert
                      out
                      (clone-type-name-canonical
                        current-module
                        (intern-str name))))
                  unit)]
              [_ unit])
            (set! index (+ index 1)))))
      out)))

(define (clone-fixpoint-step
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [names : CloneNameSet]
  [acc : CloneNameSet]) : CloneNameSet
  (clone-fixpoint-step-in-module pools decls names acc ""))

;; Initial over-approximation: every enum/struct name is assumed clone-able.
(define (clone-all-type-names-in-module
  [decls : AstDeclList]
  [acc : CloneNameSet]
  [module : String]) : CloneNameSet
  (let
    [out : CloneNameSet acc]
    [current-module : String module]
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
                (set! current-module (intern-str next-module))]
              [(AstDecl.DefEnum name _ _)
                (set!
                  out
                  (clone-name-set-insert
                    out
                    (clone-type-name-canonical current-module (intern-str name))))]
              [(AstDecl.DefStruct name _ _ _)
                (set!
                  out
                  (clone-name-set-insert
                    out
                    (clone-type-name-canonical current-module (intern-str name))))]
              [_ unit])
            (set! index (+ index 1)))))
      out)))

(define (clone-all-type-names [decls : AstDeclList] [acc : CloneNameSet]) : CloneNameSet
  (clone-all-type-names-in-module decls acc ""))

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
  [module : String]) : CloneNameList
  (clone-root-add-type-list-at pools decls able roots (& types) module 0))

(define (clone-root-add-type-list-at
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [types : (& types AstTypeList)]
  [module : String]
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
        module)
      types
      module
      (+ index 1))))

(define (clone-root-add-fields
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [fields : AstFieldDefList]
  [module : String]) : CloneNameList
  (clone-root-add-fields-at pools decls able roots (& fields) module 0))

(define (clone-root-add-fields-at
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [fields : (& fields AstFieldDefList)]
  [module : String]
  [index : i64]) : CloneNameList
  (if (>= index (ast-field-def-list-len fields))
    roots
    (match (ast-field-def-list-get fields index (ast-field-def-fallback))
      [(AstFieldDef.Def _ ty _)
        (clone-root-add-fields-at
          pools
          decls
          able
          (clone-root-add-type pools decls able roots ty module)
          fields
          module
          (+ index 1))])))

(define (clone-root-add-variants
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [variants : AstVariantDefList]
  [module : String]) : CloneNameList
  (clone-root-add-variants-at pools decls able roots (& variants) module 0))

(define (clone-root-add-variants-at
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [variants : (& variants AstVariantDefList)]
  [module : String]
  [index : i64]) : CloneNameList
  (if (>= index (ast-variant-def-list-len variants))
    roots
    (match (ast-variant-def-list-get variants index (ast-variant-def-fallback))
      [(AstVariantDef.Def _ fields _)
        (clone-root-add-variants-at
          pools
          decls
          able
          (clone-root-add-type-list pools decls able roots fields module)
          variants
          module
          (+ index 1))])))

(define (clone-root-add-name-deps-in-module
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [cursor : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [name : String]
  [module : String]) : CloneNameList
  (let
    [cur : AstDeclList cursor]
    [out : CloneNameList roots]
    [current-module : String module]
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
                    (set! current-module (intern-str next-module))
                    (set! cur rest))]
                [(AstDecl.DefEnum decl-name _ variants)
                  (if (string.eq
                    (clone-type-name-canonical
                      current-module
                      (intern-str decl-name))
                    name)
                    (begin
                      (set!
                        out
                        (clone-root-add-variants
                          pools
                          decls
                          able
                          out
                          variants
                          current-module))
                      (set! done true))
                    (set! cur rest))]
                [(AstDecl.DefStruct decl-name _ _ fields)
                  (if (string.eq
                    (clone-type-name-canonical
                      current-module
                      (intern-str decl-name))
                    name)
                    (begin
                      (set!
                        out
                        (clone-root-add-fields
                          pools
                          decls
                          able
                          out
                          fields
                          current-module))
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
  [name : String]) : CloneNameList
  (clone-root-add-name-deps-in-module pools decls cursor able roots name ""))

(define (clone-root-add-name
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [name : String]) : CloneNameList
  (if (clone-name-set-contains? able name)
    (if (clone-name-list-contains? roots name)
      roots
      (clone-root-add-name-deps
        pools
        decls
        decls
        able
        (CloneNameList.Cons name (box roots))
        name))
    roots))

(define (clone-root-add-type
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]
  [ty : AstType]
  [module : String]) : CloneNameList
  (match ty
    [(AstType.Tuple elems)
      (clone-root-add-type-list pools decls able roots (box-get elems) module)]
    [(AstType.Array elem _)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module)]
    [(AstType.DynArray elem)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module)]
    [(AstType.Box elem)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools elem)
        module)]
    [(AstType.Region _ inner)
      (clone-root-add-type
        pools
        decls
        able
        roots
        (clone-type-get pools inner)
        module)]
    [(AstType.Var name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-type-name-resolve able module (intern-str name)))]
    [(AstType.Enum name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-type-name-resolve able module (intern-str name)))]
    [(AstType.Struct name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-type-name-resolve able module (intern-str name)))]
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
          [(CloneNameList.Cons name rest)
            (let
              [with-name : CloneNameList
                (clone-root-add-name pools decls able out name)]
              (begin
                (set!
                  out
                  (clone-root-add-name-deps
                    pools
                    decls
                    decls
                    able
                    with-name
                    name))
                (set! cur (box-get rest))))]))
      out)))

;; Preserve the resolved nominal kind in the compiler-generated type literal
;; passed to the stdlib declaration macro. This is semantic type metadata, not
;; helper-family AST construction.
(define (clone-root-ast-type-in-module
  [decls : AstDeclList]
  [root : String]
  [module : String]) : AstType
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) (AstType.Var (intern root))]
    [(AstDeclListStep.Cons decl rest)
      (match (ast-decl-unwrapped decl)
        [(AstDecl.Module next-module)
          (clone-root-ast-type-in-module rest root (intern-str next-module))]
        [(AstDecl.DefStruct name _ _ _)
          (if (string.eq
            (clone-type-name-canonical module (intern-str name))
            root)
            (AstType.Struct (intern root))
            (clone-root-ast-type-in-module rest root module))]
        [(AstDecl.DefStructLifetimes name lifetimes _ _ _)
          (if (string.eq
            (clone-type-name-canonical module (intern-str name))
            root)
            (AstType.StructArgs (intern root) (box lifetimes))
            (clone-root-ast-type-in-module rest root module))]
        [(AstDecl.DefEnum name _ _)
          (if (string.eq
            (clone-type-name-canonical module (intern-str name))
            root)
            (AstType.Enum (intern root))
            (clone-root-ast-type-in-module rest root module))]
        [(AstDecl.DefEnumLifetimes name lifetimes _ _)
          (if (string.eq
            (clone-type-name-canonical module (intern-str name))
            root)
            (AstType.EnumArgs (intern root) (box lifetimes))
            (clone-root-ast-type-in-module rest root module))]
        [_ (clone-root-ast-type-in-module rest root module)])]))

(define (clone-root-ast-type [decls : AstDeclList] [root : String]) : AstType
  (clone-root-ast-type-in-module decls root ""))

(define (clone-stdlib-handoff-roots
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [roots : CloneNameList]) : CloneNameList
  (clone-root-expand pools decls able roots roots))

(define (clone-helper-decl-count-in-module
  [decls : AstDeclList]
  [root : String]
  [module : String]) : i64
  (match (ast-decl-list-step decls)
    [(AstDeclListStep.Nil) 0]
    [(AstDeclListStep.Cons decl rest)
      (match (ast-decl-unwrapped decl)
        [(AstDecl.Module next-module)
          (clone-helper-decl-count-in-module rest root (intern-str next-module))]
        [(AstDecl.DefFn name _ _ _ _)
          (+
            (if (and
              (string.eq module (clone-type-name-module root))
              (string.eq (intern-str name) (clone-local-helper-name root)))
              1
              0)
            (clone-helper-decl-count-in-module rest root module))]
        [_ (clone-helper-decl-count-in-module rest root module)])]))

(define (clone-helper-decl-count [decls : AstDeclList] [root : String]) : i64
  (clone-helper-decl-count-in-module decls root ""))

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
          [(CloneNameList.Cons name rest)
            (begin
              (set! out (clone-name-set-insert out name))
              (set! cur (box-get rest)))]))
      out)))