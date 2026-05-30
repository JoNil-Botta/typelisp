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
;; A type is clone-able iff every (transitive) field type is a scalar, a String,
;; or another clone-able named type. Types with array/tuple/dynarray/function/
;; reference fields are not yet clone-able and are skipped (cloning one is a
;; lowering error). Clone-ability is a least-fixed-point over the type graph.

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
      (if (string-eq head name) true (clone-name-list-contains? rest name))]))

;; A field type is clone-able given the current clone-able-name set: scalars and
;; String are always clone-able; a named type (parsed as AstTyVar, or resolved
;; to AstTyEnum/AstTyStruct) is clone-able iff it is in `names`; everything else
;; (arrays, tuples, dynarrays, functions, references, regions, str, Expr) is not.
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
    [(AstTyString) true]
    [(AstTyVar name) (clone-name-list-contains? names name)]
    [(AstTyEnum name) (clone-name-list-contains? names name)]
    [(AstTyStruct name) (clone-name-list-contains? names name)]
    [_ false]))

(define (clone-field-type-list-able? [types : AstTypeList] [names : CloneNameList]) : bool
  (match types
    [(AstTypeNil) true]
    [(AstTypeCons head rest)
      (if (clone-field-type-able? head names)
        (clone-field-type-list-able? rest names)
        false)]))

(define (clone-variant-list-able? [variants : AstVariantDefList] [names : CloneNameList]) : bool
  (match variants
    [(AstVariantDefNil) true]
    [(AstVariantDefCons variant rest)
      (match variant
        [(AstVariantDef _ field-types)
          (if (clone-field-type-list-able? field-types names)
            (clone-variant-list-able? rest names)
            false)])]))

(define (clone-struct-fields-able? [fields : AstFieldDefList] [names : CloneNameList]) : bool
  (match fields
    [(AstFieldDefNil) true]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef _ ty _)
          (if (clone-field-type-able? ty names)
            (clone-struct-fields-able? rest names)
            false)])]))

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
        [_ (clone-fixpoint-step rest names acc)])]))

(define (clone-name-list-len [names : CloneNameList]) : i64
  (match names
    [(CloneNameNil) 0]
    [(CloneNameCons _ rest) (+ 1 (clone-name-list-len rest))]))

;; Initial over-approximation: every enum/struct name is assumed clone-able.
(define (clone-all-type-names [decls : AstDeclList] [acc : CloneNameList]) : CloneNameList
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDefEnum name _) (clone-all-type-names rest (CloneNameCons name acc))]
        [(AstDeclDefStruct name _ _ _) (clone-all-type-names rest (CloneNameCons name acc))]
        [_ (clone-all-type-names rest acc)])]))

(define (clone-fixpoint
  [decls : AstDeclList]
  [names : CloneNameList]) : CloneNameList
  (let
    [next : CloneNameList (clone-fixpoint-step decls names (CloneNameNil))]
    (if (= (clone-name-list-len next) (clone-name-list-len names))
      next
      (clone-fixpoint decls next))))

;; --- code generation ---------------------------------------------------------

;; `(clone <expr>)`
(define (clone-call-expr [inner : AstExpr]) : AstExpr
  (AstExprCall (AstExprVar "clone") (AstExprCons inner AstExprNil)))

;; Binder name for the i-th field of a variant: tlc0, tlc1, ...
(define (clone-binder-name [i : i64]) : String
  (string-append "tlc" (int->string i)))

;; Pattern args (AstPatBinding tlc0) (AstPatBinding tlc1) ... for `count` fields.
(define (clone-variant-pat-args [count : i64] [i : i64]) : AstPatternList
  (if (>= i count)
    AstPatternNil
    (AstPatternCons
      (AstPatBinding (clone-binder-name i))
      (clone-variant-pat-args count (+ i 1)))))

;; Constructor args (clone tlc0) (clone tlc1) ... for `count` fields.
(define (clone-variant-ctor-args [count : i64] [i : i64]) : AstExprList
  (if (>= i count)
    AstExprNil
    (AstExprCons
      (clone-call-expr (AstExprVar (clone-binder-name i)))
      (clone-variant-ctor-args count (+ i 1)))))

(define (clone-type-list-len [types : AstTypeList]) : i64
  (match types
    [(AstTypeNil) 0]
    [(AstTypeCons _ rest) (+ 1 (clone-type-list-len rest))]))

;; One match arm: [(V f...) (V (clone f)...)], or [(V) (V)] for nullary variants.
(define (clone-variant-arm [variant : AstVariantDef]) : AstMatchArm
  (match variant
    [(AstVariantDef vname field-types)
      (let
        [count : i64 (clone-type-list-len field-types)]
        (AstMatchArm
          (AstPatVariant vname (clone-variant-pat-args count 0))
          (AstExprCall (AstExprVar vname) (clone-variant-ctor-args count 0))))]))

(define (clone-variant-arms [variants : AstVariantDefList]) : AstMatchArmList
  (match variants
    [(AstVariantDefNil) AstMatchArmNil]
    [(AstVariantDefCons variant rest)
      (AstMatchArmCons (clone-variant-arm variant) (clone-variant-arms rest))]))

;; Struct constructor args: (clone (struct-get x f0)) (clone (struct-get x f1)) ...
(define (clone-struct-ctor-args [fields : AstFieldDefList]) : AstExprList
  (match fields
    [(AstFieldDefNil) AstExprNil]
    [(AstFieldDefCons field rest)
      (match field
        [(AstFieldDef fname _ _)
          (AstExprCons
            (clone-call-expr (AstExprStructGet (AstExprVar "x") fname))
            (clone-struct-ctor-args rest))])]))

;; Build the `(define (clone$Name [x : Name]) : Name <body>)` declaration.
(define (clone-make-helper-decl [type-name : String] [body : AstExpr]) : AstDecl
  (AstDeclDefFn
    (clone-helper-name type-name)
    (AstParamCons (AstParam "x" (AstTyVar type-name) false) AstParamNil)
    (AstTyVar type-name)
    body))

;; Generate clone$ helpers for every clone-able enum/struct, prepended in order.
(define (clone-generate-decls
  [decls : AstDeclList]
  [able : CloneNameList]
  [acc : AstDeclList]) : AstDeclList
  (match decls
    [(AstDeclNil) acc]
    [(AstDeclCons decl rest)
      (match decl
        [(AstDeclDefEnum name variants)
          (clone-generate-decls
            rest
            able
            (if (clone-name-list-contains? able name)
              (AstDeclCons
                (clone-make-helper-decl
                  name
                  (AstExprMatch (AstExprVar "x") (clone-variant-arms variants)))
                acc)
              acc))]
        [(AstDeclDefStruct name _ _ fields)
          (clone-generate-decls
            rest
            able
            (if (clone-name-list-contains? able name)
              (AstDeclCons
                (clone-make-helper-decl
                  name
                  (AstExprCall (AstExprVar name) (clone-struct-ctor-args fields)))
                acc)
              acc))]
        [_ (clone-generate-decls rest able acc)])]))

(define (clone-decl-list-append [left : AstDeclList] [right : AstDeclList]) : AstDeclList
  (match left
    [(AstDeclNil) right]
    [(AstDeclCons head rest) (AstDeclCons head (clone-decl-list-append rest right))]))

;; Append the generated clone$ helpers AFTER the program's decls, so the real
;; declarations keep their source paths (the generated helpers, being last, get
;; the empty path on lookup). Top-level functions are mutually visible, so the
;; helpers can forward-reference the type constructors and each other.
(define (clone-augment-decls [decls : AstDeclList]) : AstDeclList
  (let
    [able : CloneNameList (clone-fixpoint decls (clone-all-type-names decls (CloneNameNil)))]
    (clone-decl-list-append decls (clone-generate-decls decls able AstDeclNil))))

(define (clone-augment-program [program : AstProgram]) : AstProgram
  (match program
    [(AstProgram decls) (AstProgram (clone-augment-decls decls))]))
