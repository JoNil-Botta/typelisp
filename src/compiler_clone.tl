;; compiler_clone.tl - synthesize clone$<Type> helpers (#1633).
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
(import stdlib.arena)
(import "compiler_string_i64_map.tl" module compiler_string_i64_map as clone_name_map)
(import stdlib.string)
(cfg test (import stdlib.test))

(defstruct CloneNameSet
  (map clone_name_map.Map))

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

(define (clone-name-set-empty) : CloneNameSet
  (CloneNameSet (clone_name_map.with-capacity 8)))

;; The fixpoint rebuilds its accepted set on each step over the whole-program
;; type universe; seeding that accumulator at the input set's capacity (it can
;; only shrink relative to the input) avoids the rehash+fill-empty grow chain a
;; capacity-8 seed would walk on every step.
(define (clone-name-set-with-capacity [capacity : i64]) : CloneNameSet
  (CloneNameSet (clone_name_map.with-capacity capacity)))

(define (clone-name-set-map [names : CloneNameSet]) : clone_name_map.Map
  (struct-get names map))

(define (clone-name-set-insert [names : CloneNameSet] [name : String]) : CloneNameSet
  (let
    [map (clone-name-set-map names)]
    (begin
      (clone_name_map.insert (&mut map) name 1)
      (CloneNameSet map))))

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

(define (clone-expr-push [pools : AstNodePoolContext] [expr : AstExpr]) : i64
  (ast-node-pool-context-expr-push pools expr))

;; A field type is clone-able given the current clone-able-name set: scalars,
;; String, tuples, fixed arrays, and dynamic arrays are clone-able recursively; a
;; named type (parsed as AstType.Var, or resolved to AstType.Enum/AstType.Struct) is
;; clone-able iff it is in `names`; everything else is not.
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
      (clone-name-set-contains-canonical? names module (intern-str name))]
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
        (clone-name-set-with-capacity (clone-name-set-capacity names)))]
    (if (= (clone-name-set-len next) (clone-name-set-len names))
      next
      (clone-fixpoint pools decls next))))

;; --- code generation ---------------------------------------------------------
;; `(clone <expr>)`
(define (clone-call-expr [pools : AstNodePoolContext] [inner : i64]) : i64
  (ast-expr-call-with-pools
    pools
    (clone-expr-push pools (AstExpr.Var (intern "clone")))
    (ast-expr-cons inner (ast-expr-list-new))))

;; Binder name for the i-th field of a variant: tlc0, tlc1, ...
(define (clone-binder-name [i : i64]) : String
  (string.append "tlc" (string.int->string i)))

;; Pattern args (AstPattern.Binding tlc0) (AstPattern.Binding tlc1) ... for `count` fields.
(define (clone-variant-pat-args [count : i64] [i : i64]) : AstPatternList
  (if (>= i count)
    (ast-pattern-list-new)
    (ast-pattern-cons
      (ast-pat-binding (clone-binder-name i))
      (clone-variant-pat-args count (+ i 1)))))

;; Constructor args (clone tlc0) (clone tlc1) ... for `count` fields.
(define (clone-variant-ctor-args
  [pools : AstNodePoolContext]
  [count : i64]
  [i : i64]) : AstExprList
  (if (>= i count)
    (ast-expr-list-new)
    (ast-expr-cons
      (clone-call-expr
        pools
        (clone-expr-push pools (AstExpr.Var (intern (clone-binder-name i)))))
      (clone-variant-ctor-args pools count (+ i 1)))))

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
        (ast-match-arm
          (ast-pat-variant-id vname (clone-variant-pat-args count 0))
          (ast-expr-call-with-pools
            pools
            (clone-expr-push pools (AstExpr.Var vname))
            (clone-variant-ctor-args pools count 0))))]))

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
              (clone-expr-push pools (AstExpr.Var (intern "x")))
              fname))
          (clone-struct-ctor-args-at pools fields (+ index 1)))])))

;; Build the `(define (clone$Name [x : Name]) : Name <body>)` declaration.
(define (clone-make-helper-decl [type-name : String] [body : i64]) : AstDecl
  (let
    [local-type-name : String (clone-type-name-base type-name)]
    (ast-decl-def-fn
      (clone-local-helper-name type-name)
      (ast-param-cons
        (ast-param "x" (AstType.Var (intern local-type-name)) false)
        (ast-param-list-new))
      (AstType.Var (intern local-type-name))
      body)))

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
  (IsList String String bool))

; nil-ctor name, cons-ctor name
(define (clone-variant-field-count [v : AstVariantDef]) : i64
  (match v
    [(AstVariantDef.Def _ field-types _) (clone-type-list-len field-types)]))

(define (clone-variant-name [v : AstVariantDef]) : String
  (match v
    [(AstVariantDef.Def name _ _) (intern-str name)]))

(define (clone-type-is-name? [ty : AstType] [name : String]) : bool
  (match ty
    [(AstType.Var n) (string.eq (intern-str n) name)]
    [(AstType.Enum n) (string.eq (intern-str n) name)]
    [_ false]))

;; True iff `tail` is the enum itself, either directly or through a Box tail.
(define (clone-tail-is-self?
  [pools : AstNodePoolContext]
  [tail : AstType]
  [self-name : String]) : bool
  (match tail
    [(AstType.Box inner)
      (clone-type-is-name? (clone-type-get pools inner) self-name)]
    [_ (clone-type-is-name? tail self-name)]))

(define (clone-tail-is-boxed-self?
  [pools : AstNodePoolContext]
  [tail : AstType]
  [self-name : String]) : bool
  (match tail
    [(AstType.Box inner)
      (clone-type-is-name? (clone-type-get pools inner) self-name)]
    [_ false]))

;; True iff `v` is a two-field variant whose SECOND field is the enum itself
;; (the `(Cons element Self)` or `(Cons element (Box Self))` shape).
(define (clone-variant-cons-tail-self?
  [pools : AstNodePoolContext]
  [v : AstVariantDef]
  [self-name : String]) : bool
  (match v
    [(AstVariantDef.Def _ field-types _)
      (and
        (= (ast-type-list-len (& field-types)) 2)
        (clone-tail-is-self?
          pools
          (clone-type-get
            pools
            (ast-type-list-get (& field-types) 1 (ast-type-id-fallback)))
          self-name))]))

(define (clone-variant-cons-tail-boxed?
  [pools : AstNodePoolContext]
  [v : AstVariantDef]
  [self-name : String]) : bool
  (match v
    [(AstVariantDef.Def _ field-types _)
      (and
        (= (ast-type-list-len (& field-types)) 2)
        (clone-tail-is-boxed-self?
          pools
          (clone-type-get
            pools
            (ast-type-list-get (& field-types) 1 (ast-type-id-fallback)))
          self-name))]))

;; If (nil-v, cons-v) form a Nil/Cons pair, return the list shape; else NotList.
(define (clone-list-shape-try
  [pools : AstNodePoolContext]
  [nil-v : AstVariantDef]
  [cons-v : AstVariantDef]
  [self-name : String]) : CloneListShape
  (if (= (clone-variant-field-count nil-v) 0)
    (if (clone-variant-cons-tail-self? pools cons-v self-name)
      (CloneListShape.IsList
        (clone-variant-name nil-v)
        (clone-variant-name cons-v)
        (clone-variant-cons-tail-boxed? pools cons-v self-name))
      (CloneListShape.NotList))
    (CloneListShape.NotList)))

;; A list-shaped enum is exactly two variants: one nullary (Nil) and one
;; `(Cons element Self)` or `(Cons element (Box Self))`, in either source order.
(define (clone-list-shape
  [pools : AstNodePoolContext]
  [variants : AstVariantDefList]
  [self-name : String]) : CloneListShape
  (if (= (ast-variant-def-list-len (& variants)) 2)
    (let
      [v1 : AstVariantDef
        (ast-variant-def-list-get (& variants) 0 (ast-variant-def-fallback))]
      [v2 : AstVariantDef
        (ast-variant-def-list-get (& variants) 1 (ast-variant-def-fallback))]
      (match (clone-list-shape-try pools v1 v2 self-name)
        [(CloneListShape.IsList n c boxed) (CloneListShape.IsList n c boxed)]
        [(CloneListShape.NotList) (clone-list-shape-try pools v2 v1 self-name)]))
    (CloneListShape.NotList)))

(define (clone-list-acc-name [type-name : String]) : String
  (string.append (clone-local-helper-name type-name) "$acc"))

(define (clone-list-rev-name [type-name : String]) : String
  (string.append (clone-local-helper-name type-name) "$rev"))

;; `(Nil)` - a nullary constructor is a zero-arg call, as in clone-variant-arm.
(define (clone-nil-expr [pools : AstNodePoolContext] [nil-ctor : String]) : i64
  (ast-expr-call-with-pools
    pools
    (clone-expr-push pools (AstExpr.Var (intern nil-ctor)))
    (ast-expr-list-new)))

(define (clone-list-tail-next-expr
  [pools : AstNodePoolContext]
  [boxed-tail : bool]) : i64
  (if boxed-tail
    (ast-expr-box-get-with-pools
      pools
      (clone-expr-push pools (AstExpr.Var (intern "t"))))
    (clone-expr-push pools (AstExpr.Var (intern "t")))))

(define (clone-list-tail-acc-expr
  [pools : AstNodePoolContext]
  [boxed-tail : bool]) : i64
  (if boxed-tail
    (ast-expr-box-with-pools
      pools
      (clone-expr-push pools (AstExpr.Var (intern "acc"))))
    (clone-expr-push pools (AstExpr.Var (intern "acc")))))

;; A two-parameter `(define (fn [x : T] [acc : T]) : T body)`.
(define (clone-make-list-fn
  [fn-name : String]
  [type-name : String]
  [body : i64]) : AstDecl
  (let
    [local-type-name : String (clone-type-name-base type-name)]
    (ast-decl-def-fn
      fn-name
      (ast-param-cons
        (ast-param "x" (AstType.Var (intern local-type-name)) false)
        (ast-param-cons
          (ast-param "acc" (AstType.Var (intern local-type-name)) false)
          (ast-param-list-new)))
      (AstType.Var (intern local-type-name))
      body)))

;; The `(Cons-pattern h t)` -> recursive-tail-call match arm shared by acc/rev.
;; `head-expr` is the head placed into the rebuilt cons (cloned for acc, bare
;; for rev). `fn-name` is the function to tail-call.
(define (clone-list-step-arm
  [pools : AstNodePoolContext]
  [fn-name : String]
  [cons-ctor : String]
  [boxed-tail : bool]
  [head-expr : i64]) : AstMatchArm
  (ast-match-arm
    (ast-pat-variant
      cons-ctor
      (ast-pattern-cons
        (ast-pat-binding "h")
        (ast-pattern-cons (ast-pat-binding "t") (ast-pattern-list-new))))
    (ast-expr-call-with-pools
      pools
      (clone-expr-push pools (AstExpr.Var (intern fn-name)))
      (ast-expr-cons
        (clone-list-tail-next-expr pools boxed-tail)
        (ast-expr-cons
          (ast-expr-call-with-pools
            pools
            (clone-expr-push pools (AstExpr.Var (intern cons-ctor)))
            (ast-expr-cons
              head-expr
              (ast-expr-cons
                (clone-list-tail-acc-expr pools boxed-tail)
                (ast-expr-list-new))))
          (ast-expr-list-new))))))

;; (match x [(Nil) acc] [(Cons h t) (fn t (Cons head-expr acc))])
(define (clone-list-fold-body
  [pools : AstNodePoolContext]
  [fn-name : String]
  [nil-ctor : String]
  [cons-ctor : String]
  [boxed-tail : bool]
  [head-expr : i64]) : i64
  (ast-expr-match-with-pools
    pools
    (clone-expr-push pools (AstExpr.Var (intern "x")))
    (ast-match-arm-cons
      (ast-match-arm
        (ast-pat-variant nil-ctor (ast-pattern-list-new))
        (clone-expr-push pools (AstExpr.Var (intern "acc"))))
      (ast-match-arm-cons
        (clone-list-step-arm pools fn-name cons-ctor boxed-tail head-expr)
        (ast-match-arm-list-new)))))

;; clone$L$acc: tail-recursively clone each element into a reversed accumulator.
(define (clone-list-acc-decl
  [pools : AstNodePoolContext]
  [type-name : String]
  [nil-ctor : String]
  [cons-ctor : String]
  [boxed-tail : bool]) : AstDecl
  (let
    [fn-name : String (clone-list-acc-name type-name)]
    (clone-make-list-fn
      fn-name
      type-name
      (clone-list-fold-body
        pools
        fn-name
        nil-ctor
        cons-ctor
        boxed-tail
        (clone-call-expr
          pools
          (clone-expr-push pools (AstExpr.Var (intern "h"))))))))

;; clone$L$rev: tail-recursively reverse (no cloning) to restore source order.
(define (clone-list-rev-decl
  [pools : AstNodePoolContext]
  [type-name : String]
  [nil-ctor : String]
  [cons-ctor : String]
  [boxed-tail : bool]) : AstDecl
  (let
    [fn-name : String (clone-list-rev-name type-name)]
    (clone-make-list-fn
      fn-name
      type-name
      (clone-list-fold-body
        pools
        fn-name
        nil-ctor
        cons-ctor
        boxed-tail
        (clone-expr-push pools (AstExpr.Var (intern "h")))))))

;; clone$L: reverse(acc(x, Nil), Nil) - both folds run in O(1) stack frames.
(define (clone-list-entry-decl
  [pools : AstNodePoolContext]
  [type-name : String]
  [nil-ctor : String]) : AstDecl
  (clone-make-helper-decl
    type-name
    (ast-expr-call-with-pools
      pools
      (clone-expr-push
        pools
        (AstExpr.Var (intern (clone-list-rev-name type-name))))
      (ast-expr-cons
        (ast-expr-call-with-pools
          pools
          (clone-expr-push
            pools
            (AstExpr.Var (intern (clone-list-acc-name type-name))))
          (ast-expr-cons
            (clone-expr-push pools (AstExpr.Var (intern "x")))
            (ast-expr-cons (clone-nil-expr pools nil-ctor) (ast-expr-list-new))))
        (ast-expr-cons (clone-nil-expr pools nil-ctor) (ast-expr-list-new))))))

;; Emit the clone helper(s) for one clone-able enum: three tail-recursive
;; functions for a list shape, otherwise the single naive match-reconstruct.
(define (clone-emit-enum-clone
  [pools : AstNodePoolContext]
  [name : String]
  [variants : AstVariantDefList]
  [acc : AstDeclList]) : AstDeclList
  (match (clone-list-shape pools variants name)
    [(CloneListShape.IsList nil-ctor cons-ctor boxed-tail)
      (let
        [qualified-nil : String
          (clone-list-variant-reference-name name nil-ctor)]
        [qualified-cons : String
          (clone-list-variant-reference-name name cons-ctor)]
        (ast-decl-list-prepend-builder
          (clone-list-entry-decl pools name qualified-nil)
          (ast-decl-list-prepend-builder
            (clone-list-acc-decl
              pools
              name
              qualified-nil
              qualified-cons
              boxed-tail)
            (ast-decl-list-prepend-builder
              (clone-list-rev-decl
                pools
                name
                qualified-nil
                qualified-cons
                boxed-tail)
              acc))))]
    [(CloneListShape.NotList)
      (ast-decl-list-prepend-builder
        (clone-make-helper-decl
          name
          (ast-expr-match-with-pools
            pools
            (clone-expr-push pools (AstExpr.Var (intern "x")))
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
        (ast-ty-box-with-pools pools (AstType.Var (intern "CloneShortList")))]
      [cons-fields : AstTypeList
        (ast-type-cons-with-pools
          pools
          (AstType.I64)
          (ast-type-cons-with-pools pools tail-ty (ast-type-list-new)))]
      (ast-variant-def-cons
        (AstVariantDef.Def
          (intern "Nil")
          (ast-type-list-new)
          (ast-variant-payload-cleanup-list-new))
        (ast-variant-def-cons
          (AstVariantDef.Def
            (intern "Cons")
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
          "CloneShortList"
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
  [module : String]
  [generated : AstDeclList]
  [acc : AstDeclList]) : AstDeclList
  (if (string.eq module "")
    (clone-decl-list-append generated acc)
    (ast-decl-list-prepend-builder
      (ast-decl-module module)
      (clone-decl-list-append generated acc))))

(define (clone-generate-decls-in-module
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [acc : AstDeclList]
  [module : String]) : AstDeclList
  (let
    [cur : AstDeclList decls]
    [out : AstDeclList acc]
    [current-module : String module]
    (begin
      (while (match (ast-decl-list-step cur)
        [(AstDeclListStep.Nil) false]
        [_ true])
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
                [(AstDecl.DefEnum name _ variants)
                  (let
                    [name-str : String
                      (clone-type-name-canonical
                        current-module
                        (intern-str name))]
                    (begin
                      (if (clone-name-set-contains? able name-str)
                        (set!
                          out
                          (clone-prepend-generated-decls-in-module
                            current-module
                            (clone-emit-enum-clone
                              pools
                              name-str
                              variants
                              (ast-decl-list-new))
                            out))
                        unit)
                      (set! cur rest)))]
                [(AstDecl.DefStruct name _ _ fields)
                  (let
                    [name-str : String
                      (clone-type-name-canonical
                        current-module
                        (intern-str name))]
                    (begin
                      (if (clone-name-set-contains? able name-str)
                        (set!
                          out
                          (clone-prepend-generated-decls-in-module
                            current-module
                            (ast-decl-list-prepend-builder
                              (clone-make-helper-decl
                                name-str
                                (ast-expr-call-with-pools
                                  pools
                                  (clone-expr-push pools (AstExpr.Var name))
                                  (clone-struct-ctor-args pools fields)))
                              (ast-decl-list-new))
                            out))
                        unit)
                      (set! cur rest)))]
                [_ (set! cur rest)]))]))
      out)))

(define (clone-generate-decls
  [pools : AstNodePoolContext]
  [decls : AstDeclList]
  [able : CloneNameSet]
  [acc : AstDeclList]) : AstDeclList
  (clone-generate-decls-in-module pools decls able acc ""))

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
        (clone-type-name-canonical module (intern-str name)))]
    [(AstType.Enum name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-type-name-canonical module (intern-str name)))]
    [(AstType.Struct name)
      (clone-root-add-name
        pools
        decls
        able
        roots
        (clone-type-name-canonical module (intern-str name)))]
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