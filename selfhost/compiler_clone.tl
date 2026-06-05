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
(import "../stdlib/io.tl")

(import "compiler_ast_types.tl")

(defenum CloneNameList
  (CloneNameNil)
  (CloneNameCons String CloneNameList))

(define (clone-helper-name [type-name : String]) : String
  (string-append "clone$" type-name))

(define (clone-name-list-contains? [names : CloneNameList] [name : String]) : bool
  (match names
    [(CloneNameNil) false]
    [(CloneNameCons head rest)
      (if (string-eq head name)
        true
        (clone-name-list-contains? rest name))]))

;; A field type is clone-able given the current clone-able-name set: scalars,
;; String, tuples, fixed arrays, and dynamic arrays are clone-able recursively; a
;; named type (parsed as AstTyVar, or resolved to AstTyEnum/AstTyStruct) is
;; clone-able iff it is in `names`; everything else is not.
(define (clone-field-type-able? [ty : AstType] [names : CloneNameList]) : bool
  (match ty
    [(AstTyI64) true]
    [(AstTyI32) true]
    [(AstTyI16) true]
    [(AstTyI8) true]
    [(AstTyU64) true]
    [(AstTyU32) true]
    [(AstTyU16) true]
    [(AstTyU8) true]
    [(AstTyF64) true]
    [(AstTyF32) true]
    [(AstTyBool) true]
    [(AstTyChar) true]
    [(AstTyUnit) true]
    [(AstTyNever) true]
    [(AstTyString) true]
    [(AstTyTuple elems) (clone-field-type-list-able? elems names)]
    [(AstTyArray elem _) (clone-field-type-able? (box-get elem) names)]
    [(AstTyDynArray elem) (clone-field-type-able? (box-get elem) names)]
    [(AstTyBox elem) (clone-field-type-able? (box-get elem) names)]
    [(AstTyRegion _ inner) (clone-field-type-able? (box-get inner) names)]
    [(AstTyVar name) (clone-name-list-contains? names name)]
    [(AstTyEnum name) (clone-name-list-contains? names name)]
    [(AstTyStruct name) (clone-name-list-contains? names name)]
    [_ false]))

(define (clone-field-type-list-able?
  [types : AstTypeList]
  [names : CloneNameList]) : bool
  (match types
    [(AstTypeNil) true]
    [(AstTypeCons head rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (if (clone-field-type-able? head names)
          (clone-field-type-list-able? rest names)
          false))]))

(define (clone-variant-list-able?
  [variants : AstVariantDefList]
  [names : CloneNameList]) : bool
  (match variants
    [(AstVariantDefNil) true]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ field-types)
            (if (clone-field-type-list-able? field-types names)
              (clone-variant-list-able? rest names)
              false)]))]))

(define (clone-struct-fields-able?
  [fields : AstFieldDefList]
  [names : CloneNameList]) : bool
  (match fields
    [(AstFieldDefNil) true]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (if (clone-field-type-able? ty names)
              (clone-struct-fields-able? rest names)
              false)]))]))

;; One fixpoint step: keep only names whose declaration's fields are all
;; clone-able under the current `names` set. Repeats until the set stops
;; shrinking (monotone decreasing, so it terminates).
(define (clone-fixpoint-step
  [decls : AstDeclList]
  [names : CloneNameList]
  [acc : CloneNameList]) : CloneNameList
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefEnum name variants)
            (clone-fixpoint-step
              rest
              names
              (if (clone-variant-list-able? variants names)
                (CloneNameCons name acc)
                acc))]
          [(AstDeclDefStruct name _ _ fields)
            (clone-fixpoint-step
              rest
              names
              (if (clone-struct-fields-able? fields names)
                (CloneNameCons name acc)
                acc))]
          [_ (clone-fixpoint-step rest names acc)]))]))

(define (clone-name-list-len [names : CloneNameList]) : i64
  (match names
    [(CloneNameNil) 0]
    [(CloneNameCons _ rest) (+ 1 (clone-name-list-len rest))]))

;; Initial over-approximation: every enum/struct name is assumed clone-able.
(define (clone-all-type-names [decls : AstDeclList] [acc : CloneNameList]) : CloneNameList
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefEnum name _)
            (clone-all-type-names rest (CloneNameCons name acc))]
          [(AstDeclDefStruct name _ _ _)
            (clone-all-type-names rest (CloneNameCons name acc))]
          [_ (clone-all-type-names rest acc)]))]))

(define (clone-fixpoint [decls : AstDeclList] [names : CloneNameList]) : CloneNameList
  (let
    [next : CloneNameList (clone-fixpoint-step decls names (CloneNameNil))]
    (if (= (clone-name-list-len next) (clone-name-list-len names))
      next
      (clone-fixpoint decls next))))

;; --- code generation ---------------------------------------------------------
;; `(clone <expr>)`
(define (clone-call-expr [inner : AstExpr]) : AstExpr
  (ast-expr-call (AstExprVar "clone") (ast-expr-cons inner AstExprNil)))

;; Binder name for the i-th field of a variant: tlc0, tlc1, ...
(define (clone-binder-name [i : i64]) : String
  (string-append "tlc" (int->string i)))

;; Pattern args (AstPatBinding tlc0) (AstPatBinding tlc1) ... for `count` fields.
(define (clone-variant-pat-args [count : i64] [i : i64]) : AstPatternList
  (if (>= i count)
    AstPatternNil
    (ast-pattern-cons
      (AstPatBinding (clone-binder-name i))
      (clone-variant-pat-args count (+ i 1)))))

;; Constructor args (clone tlc0) (clone tlc1) ... for `count` fields.
(define (clone-variant-ctor-args [count : i64] [i : i64]) : AstExprList
  (if (>= i count)
    AstExprNil
    (ast-expr-cons
      (clone-call-expr (AstExprVar (clone-binder-name i)))
      (clone-variant-ctor-args count (+ i 1)))))

(define (clone-type-list-len [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (+ 1 (clone-type-list-len rest)))]))

;; One match arm: [(V f...) (V (clone f)...)], or [(V) (V)] for nullary variants.
(define (clone-variant-arm [variant : AstVariantDef]) : AstMatchArm
  (match variant
    [(AstVariantDef vname field-types)
      (let
        [count : i64 (clone-type-list-len field-types)]
        (ast-match-arm
          (ast-pat-variant vname (clone-variant-pat-args count 0))
          (ast-expr-call (AstExprVar vname) (clone-variant-ctor-args count 0))))]))

(define (clone-variant-arms [variants : AstVariantDefList]) : AstMatchArmList
  (match variants
    [(AstVariantDefNil) AstMatchArmNil]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (ast-match-arm-cons
          (clone-variant-arm variant)
          (clone-variant-arms rest)))]))

;; Struct constructor args: (clone (struct-get x f0)) (clone (struct-get x f1)) ...
(define (clone-struct-ctor-args [fields : AstFieldDefList]) : AstExprList
  (match fields
    [(AstFieldDefNil) AstExprNil]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef fname _ _)
            (ast-expr-cons
              (clone-call-expr (ast-expr-struct-get (AstExprVar "x") fname))
              (clone-struct-ctor-args rest))]))]))

;; Build the `(define (clone$Name [x : Name]) : Name <body>)` declaration.
(define (clone-make-helper-decl [type-name : String] [body : AstExpr]) : AstDecl
  (AstDeclDefFn
    (clone-helper-name type-name)
    (ast-param-cons (AstParam "x" (AstTyVar type-name) false) AstParamNil)
    (AstTyVar type-name)
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
  (CloneNotList)
  (CloneIsList String String bool))

; nil-ctor name, cons-ctor name
(define (clone-variant-field-count [v : AstVariantDef]) : i64
  (match v
    [(AstVariantDef _ field-types) (clone-type-list-len field-types)]))

(define (clone-variant-name [v : AstVariantDef]) : String
  (match v
    [(AstVariantDef name _) name]))

(define (clone-type-is-name? [ty : AstType] [name : String]) : bool
  (match ty
    [(AstTyVar n) (string-eq n name)]
    [(AstTyEnum n) (string-eq n name)]
    [_ false]))

;; True iff `tail` is the enum itself, either directly or through a Box tail.
(define (clone-tail-is-self? [tail : AstType] [self-name : String]) : bool
  (match tail
    [(AstTyBox inner) (clone-type-is-name? (box-get inner) self-name)]
    [_ (clone-type-is-name? tail self-name)]))

(define (clone-tail-is-boxed-self? [tail : AstType] [self-name : String]) : bool
  (match tail
    [(AstTyBox inner) (clone-type-is-name? (box-get inner) self-name)]
    [_ false]))

;; True iff `v` is a two-field variant whose SECOND field is the enum itself
;; (the `(Cons element Self)` or `(Cons element (Box Self))` shape).
(define (clone-variant-cons-tail-self? [v : AstVariantDef] [self-name : String]) : bool
  (match v
    [(AstVariantDef _ field-types)
      (match field-types
        [(AstTypeCons _ tail)
          (let
            [tail : AstTypeList (box-get tail)]
            (match tail
              [(AstTypeCons tail-ty rest)
                (let
                  [rest : AstTypeList (box-get rest)]
                  (match rest
                    [(AstTypeNil) (clone-tail-is-self? tail-ty self-name)]
                    [_ false]))]
              [_ false]))]
        [_ false])]))

(define (clone-variant-cons-tail-boxed?
  [v : AstVariantDef]
  [self-name : String]) : bool
  (match v
    [(AstVariantDef _ field-types)
      (match field-types
        [(AstTypeCons _ tail)
          (let
            [tail : AstTypeList (box-get tail)]
            (match tail
              [(AstTypeCons tail-ty rest)
                (let
                  [rest : AstTypeList (box-get rest)]
                  (match rest
                    [(AstTypeNil) (clone-tail-is-boxed-self? tail-ty self-name)]
                    [_ false]))]
              [_ false]))]
        [_ false])]))

;; If (nil-v, cons-v) form a Nil/Cons pair, return the list shape; else NotList.
(define (clone-list-shape-try
  [nil-v : AstVariantDef]
  [cons-v : AstVariantDef]
  [self-name : String]) : CloneListShape
  (if (= (clone-variant-field-count nil-v) 0)
    (if (clone-variant-cons-tail-self? cons-v self-name)
      (CloneIsList
        (clone-variant-name nil-v)
        (clone-variant-name cons-v)
        (clone-variant-cons-tail-boxed? cons-v self-name))
      (CloneNotList))
    (CloneNotList)))

;; A list-shaped enum is exactly two variants: one nullary (Nil) and one
;; `(Cons element Self)` or `(Cons element (Box Self))`, in either source order.
(define (clone-list-shape [variants : AstVariantDefList] [self-name : String]) : CloneListShape
  (match variants
    [(AstVariantDefCons v1 tail)
      (let
        [tail : AstVariantDefList (box-get tail)]
        (match tail
          [(AstVariantDefCons v2 rest)
            (let
              [rest : AstVariantDefList (box-get rest)]
              (match rest
                [(AstVariantDefNil)
                  (match (clone-list-shape-try v1 v2 self-name)
                    [(CloneIsList n c boxed) (CloneIsList n c boxed)]
                    [(CloneNotList) (clone-list-shape-try v2 v1 self-name)])]
                [_ (CloneNotList)]))]
          [_ (CloneNotList)]))]
    [_ (CloneNotList)]))

(define (clone-list-acc-name [type-name : String]) : String
  (string-append (clone-helper-name type-name) "$acc"))

(define (clone-list-rev-name [type-name : String]) : String
  (string-append (clone-helper-name type-name) "$rev"))

;; `(Nil)` — a nullary constructor is a zero-arg call, as in clone-variant-arm.
(define (clone-nil-expr [nil-ctor : String]) : AstExpr
  (ast-expr-call (AstExprVar nil-ctor) AstExprNil))

(define (clone-list-tail-next-expr [boxed-tail : bool]) : AstExpr
  (if boxed-tail
    (ast-expr-box-get (AstExprVar "t"))
    (AstExprVar "t")))

(define (clone-list-tail-acc-expr [boxed-tail : bool]) : AstExpr
  (if boxed-tail
    (ast-expr-box (AstExprVar "acc"))
    (AstExprVar "acc")))

;; A two-parameter `(define (fn [x : T] [acc : T]) : T body)`.
(define (clone-make-list-fn
  [fn-name : String]
  [type-name : String]
  [body : AstExpr]) : AstDecl
  (AstDeclDefFn
    fn-name
    (ast-param-cons
      (AstParam "x" (AstTyVar type-name) false)
      (ast-param-cons (AstParam "acc" (AstTyVar type-name) false) AstParamNil))
    (AstTyVar type-name)
    body))

;; The `(Cons-pattern h t)` -> recursive-tail-call match arm shared by acc/rev.
;; `head-expr` is the head placed into the rebuilt cons (cloned for acc, bare
;; for rev). `fn-name` is the function to tail-call.
(define (clone-list-step-arm
  [fn-name : String]
  [cons-ctor : String]
  [boxed-tail : bool]
  [head-expr : AstExpr]) : AstMatchArm
  (ast-match-arm
    (ast-pat-variant
      cons-ctor
      (ast-pattern-cons
        (AstPatBinding "h")
        (ast-pattern-cons (AstPatBinding "t") AstPatternNil)))
    (ast-expr-call
      (AstExprVar fn-name)
      (ast-expr-cons
        (clone-list-tail-next-expr boxed-tail)
        (ast-expr-cons
          (ast-expr-call
            (AstExprVar cons-ctor)
            (ast-expr-cons
              head-expr
              (ast-expr-cons (clone-list-tail-acc-expr boxed-tail) AstExprNil)))
          AstExprNil)))))

;; (match x [(Nil) acc] [(Cons h t) (fn t (Cons head-expr acc))])
(define (clone-list-fold-body
  [fn-name : String]
  [nil-ctor : String]
  [cons-ctor : String]
  [boxed-tail : bool]
  [head-expr : AstExpr]) : AstExpr
  (ast-expr-match
    (AstExprVar "x")
    (ast-match-arm-cons
      (ast-match-arm
        (ast-pat-variant nil-ctor AstPatternNil)
        (AstExprVar "acc"))
      (ast-match-arm-cons
        (clone-list-step-arm fn-name cons-ctor boxed-tail head-expr)
        AstMatchArmNil))))

;; clone$L$acc: tail-recursively clone each element into a reversed accumulator.
(define (clone-list-acc-decl
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
        fn-name
        nil-ctor
        cons-ctor
        boxed-tail
        (clone-call-expr (AstExprVar "h"))))))

;; clone$L$rev: tail-recursively reverse (no cloning) to restore source order.
(define (clone-list-rev-decl
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
        fn-name
        nil-ctor
        cons-ctor
        boxed-tail
        (AstExprVar "h")))))

;; clone$L: reverse(acc(x, Nil), Nil) — both folds run in O(1) stack frames.
(define (clone-list-entry-decl [type-name : String] [nil-ctor : String]) : AstDecl
  (clone-make-helper-decl
    type-name
    (ast-expr-call
      (AstExprVar (clone-list-rev-name type-name))
      (ast-expr-cons
        (ast-expr-call
          (AstExprVar (clone-list-acc-name type-name))
          (ast-expr-cons
            (AstExprVar "x")
            (ast-expr-cons (clone-nil-expr nil-ctor) AstExprNil)))
        (ast-expr-cons (clone-nil-expr nil-ctor) AstExprNil)))))

;; Emit the clone helper(s) for one clone-able enum: three tail-recursive
;; functions for a list shape, otherwise the single naive match-reconstruct.
(define (clone-emit-enum-clone
  [name : String]
  [variants : AstVariantDefList]
  [acc : AstDeclList]) : AstDeclList
  (match (clone-list-shape variants name)
    [(CloneIsList nil-ctor cons-ctor boxed-tail)
      (ast-decl-cons
        (clone-list-entry-decl name nil-ctor)
        (ast-decl-cons
          (clone-list-acc-decl name nil-ctor cons-ctor boxed-tail)
          (ast-decl-cons
            (clone-list-rev-decl name nil-ctor cons-ctor boxed-tail)
            acc)))]
    [(CloneNotList)
      (ast-decl-cons
        (clone-make-helper-decl
          name
          (ast-expr-match (AstExprVar "x") (clone-variant-arms variants)))
        acc)]))

;; Generate clone$ helpers for every clone-able enum/struct, prepended in order.
(define (clone-generate-decls
  [decls : AstDeclList]
  [able : CloneNameList]
  [acc : AstDeclList]) : AstDeclList
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefEnum name variants)
            (clone-generate-decls
              rest
              able
              (if (clone-name-list-contains? able name)
                (clone-emit-enum-clone name variants acc)
                acc))]
          [(AstDeclDefStruct name _ _ fields)
            (clone-generate-decls
              rest
              able
              (if (clone-name-list-contains? able name)
                (ast-decl-cons
                  (clone-make-helper-decl
                    name
                    (ast-expr-call
                      (AstExprVar name)
                      (clone-struct-ctor-args fields)))
                  acc)
                acc))]
          [_ (clone-generate-decls rest able acc)]))]))

(define (clone-decl-list-append [left : AstDeclList] [right : AstDeclList]) : AstDeclList
  (match left
    [(AstDeclNil) right]
    [(AstDeclCons head rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (ast-decl-cons head (clone-decl-list-append rest right)))]))

(define (clone-root-add-type-list
  [decls : AstDeclList]
  [able : CloneNameList]
  [roots : CloneNameList]
  [types : AstTypeList]) : CloneNameList
  (match types
    [(AstTypeNil) roots]
    [(AstTypeCons head rest)
      (let
        [rest : AstTypeList (box-get rest)]
        (clone-root-add-type-list
          decls
          able
          (clone-root-add-type decls able roots head)
          rest))]))

(define (clone-root-add-fields
  [decls : AstDeclList]
  [able : CloneNameList]
  [roots : CloneNameList]
  [fields : AstFieldDefList]) : CloneNameList
  (match fields
    [(AstFieldDefNil) roots]
    [(AstFieldDefCons field rest)
      (let
        [rest : AstFieldDefList (box-get rest)]
        (match field
          [(AstFieldDef _ ty _)
            (clone-root-add-fields
              decls
              able
              (clone-root-add-type decls able roots ty)
              rest)]))]))

(define (clone-root-add-variants
  [decls : AstDeclList]
  [able : CloneNameList]
  [roots : CloneNameList]
  [variants : AstVariantDefList]) : CloneNameList
  (match variants
    [(AstVariantDefNil) roots]
    [(AstVariantDefCons variant rest)
      (let
        [rest : AstVariantDefList (box-get rest)]
        (match variant
          [(AstVariantDef _ fields)
            (clone-root-add-variants
              decls
              able
              (clone-root-add-type-list decls able roots fields)
              rest)]))]))

(define (clone-root-add-name-deps
  [decls : AstDeclList]
  [cursor : AstDeclList]
  [able : CloneNameList]
  [roots : CloneNameList]
  [name : String]) : CloneNameList
  (match cursor
    [(AstDeclNil) roots]
    [(AstDeclCons decl rest)
      (let
        [rest : AstDeclList (box-get rest)]
        (match decl
          [(AstDeclDefEnum decl-name variants)
            (if (string-eq decl-name name)
              (clone-root-add-variants decls able roots variants)
              (clone-root-add-name-deps decls rest able roots name))]
          [(AstDeclDefStruct decl-name _ _ fields)
            (if (string-eq decl-name name)
              (clone-root-add-fields decls able roots fields)
              (clone-root-add-name-deps decls rest able roots name))]
          [_ (clone-root-add-name-deps decls rest able roots name)]))]))

(define (clone-root-add-name
  [decls : AstDeclList]
  [able : CloneNameList]
  [roots : CloneNameList]
  [name : String]) : CloneNameList
  (if (clone-name-list-contains? able name)
    (if (clone-name-list-contains? roots name)
      roots
      (clone-root-add-name-deps
        decls
        decls
        able
        (CloneNameCons name roots)
        name))
    roots))

(define (clone-root-add-type
  [decls : AstDeclList]
  [able : CloneNameList]
  [roots : CloneNameList]
  [ty : AstType]) : CloneNameList
  (match ty
    [(AstTyTuple elems) (clone-root-add-type-list decls able roots elems)]
    [(AstTyArray elem _) (clone-root-add-type decls able roots (box-get elem))]
    [(AstTyDynArray elem) (clone-root-add-type decls able roots (box-get elem))]
    [(AstTyBox elem) (clone-root-add-type decls able roots (box-get elem))]
    [(AstTyRegion _ inner)
      (clone-root-add-type decls able roots (box-get inner))]
    [(AstTyVar name) (clone-root-add-name decls able roots name)]
    [(AstTyEnum name) (clone-root-add-name decls able roots name)]
    [(AstTyStruct name) (clone-root-add-name decls able roots name)]
    [_ roots]))

(define (clone-root-expand
  [decls : AstDeclList]
  [able : CloneNameList]
  [roots : CloneNameList]
  [cursor : CloneNameList]) : CloneNameList
  (match cursor
    [(CloneNameNil) roots]
    [(CloneNameCons name rest)
      (let
        [with-name : CloneNameList (clone-root-add-name decls able roots name)]
        (clone-root-expand
          decls
          able
          (clone-root-add-name-deps decls decls able with-name name)
          rest))]))

;; Append the generated clone$ helpers AFTER the program's decls, so the real
;; declarations keep their source paths (the generated helpers, being last, get
;; the empty path on lookup). Top-level functions are mutually visible, so the
;; helpers can forward-reference the type constructors and each other.
(define (clone-augment-decls [decls : AstDeclList]) : AstDeclList
  (let
    [able : CloneNameList
      (clone-fixpoint decls (clone-all-type-names decls (CloneNameNil)))]
    (clone-decl-list-append decls (clone-generate-decls decls able AstDeclNil))))

(define (clone-augment-decls-with-roots
  [decls : AstDeclList]
  [roots : CloneNameList]) : AstDeclList
  (let
    [able : CloneNameList
      (clone-fixpoint decls (clone-all-type-names decls (CloneNameNil)))]
    [expanded : CloneNameList (clone-root-expand decls able roots roots)]
    (clone-decl-list-append
      decls
      (clone-generate-decls decls expanded AstDeclNil))))

(define (clone-augment-program [program : AstProgram]) : AstProgram
  (match program
    [(AstProgram decls) (AstProgram (clone-augment-decls decls))]))

(define (clone-augment-program-with-roots
  [program : AstProgram]
  [roots : CloneNameList]) : AstProgram
  (match program
    [(AstProgram decls)
      (AstProgram (clone-augment-decls-with-roots decls roots))]))