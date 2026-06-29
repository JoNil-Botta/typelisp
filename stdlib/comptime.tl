;# Public compile-time syntax and reflection surface.
;#
;# This module owns the stdlib-side declarations for the well-known comptime
;# types described by SPEC 3.7.2.2. The current compiler still stores macro
;# syntax internally as `AstTyExpr` / `CompilerCtfeValue.Expr`; it verifies these declarations
;# and treats the syntax types as aliases for that internal representation while
;# the CTFE value migration lands.
;#
;# CTFE still intercepts constructor, sequence, and reflection helper calls
;# because it cannot yet interpret arbitrary stdlib function calls and several
;# constructors attach compiler provenance. Simple `Expr`/`ExprClause`
;# inspectors below are ordinary source bodies so macro code can migrate toward
;# public pattern matching without growing the bridge surface.
(module stdlib.comptime)

;# `feature-plain-comptime-well-known` is the end-state source surface. The
;# inverse cfg branch is a temporary bridge for published stage0 compilers whose
;# verifier still requires legacy generated metadata.
;: Syntax value passed to and returned from expression macros.
(cfg
  feature-plain-comptime-well-known
  (defenum Expr
    (ExprBool bool)
    (ExprInt i64)
    (ExprVar String)
    (ExprSplice (Box Expr))
    (ExprIf (Box Expr) (Box Expr) (Box Expr))
    (ExprCall (Box Expr) ExprList)
    (ExprBegin ExprList)
    (ExprQuote (Box Expr))
    (ExprQuasiquote (Box Expr))
    (ExprUnquote (Box Expr))
    (ExprUnquoteSplicing (Box Expr))))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known Expr "v0")
    (defenum Expr
      (ExprBool bool)
      (ExprInt i64)
      (ExprVar String)
      (ExprSplice (Box Expr))
      (ExprIf (Box Expr) (Box Expr) (Box Expr))
      (ExprCall (Box Expr) ExprList)
      (ExprBegin ExprList)
      (ExprQuote (Box Expr))
      (ExprQuasiquote (Box Expr))
      (ExprUnquote (Box Expr))
      (ExprUnquoteSplicing (Box Expr)))))

;: Dense ordered sequence of syntax expressions.
(cfg
  feature-plain-comptime-well-known
  (defstruct ExprList
    (items (Array Expr))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known ExprList "v0")
    (defstruct ExprList
      (items (Array Expr))
      (len i64))))

;: Pair of expressions used by clause-oriented macro forms.
(cfg
  feature-plain-comptime-well-known
  (defstruct ExprClause
    (first Expr)
    (second Expr)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known ExprClause "v0")
    (defstruct ExprClause
      (first Expr)
      (second Expr))))

;: Dense ordered sequence of expression clauses.
(cfg
  feature-plain-comptime-well-known
  (defstruct ExprClauseList
    (items (Array ExprClause))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known ExprClauseList "v0")
    (defstruct ExprClauseList
      (items (Array ExprClause))
      (len i64))))

;: Let-like binding clause used by binding-introducing macro forms.
(cfg
  feature-plain-comptime-well-known
  (defstruct ExprBindingClause
    (name String)
    (has-type bool)
    (ty Expr)
    (init Expr)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known ExprBindingClause "v0")
    (defstruct ExprBindingClause
      (name String)
      (has-type bool)
      (ty Expr)
      (init Expr))))

;: Dense ordered sequence of binding clauses.
(cfg
  feature-plain-comptime-well-known
  (defstruct ExprBindingClauseList
    (items (Array ExprBindingClause))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known ExprBindingClauseList "v0")
    (defstruct ExprBindingClauseList
      (items (Array ExprBindingClause))
      (len i64))))

;: Match pattern syntax value built during macro CTFE.
(cfg
  feature-plain-comptime-well-known
  (defenum Pattern
    (PatternWildcard)
    (PatternBinding String)
    (PatternVariant String PatternList)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known Pattern "v0")
    (defenum Pattern
      (PatternWildcard)
      (PatternBinding String)
      (PatternVariant String PatternList))))

;: Dense ordered sequence of match pattern syntax values.
(cfg
  feature-plain-comptime-well-known
  (defstruct PatternList
    (items (Array Pattern))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known PatternList "v0")
    (defstruct PatternList
      (items (Array Pattern))
      (len i64))))

;: Generated match arm made from a pattern and result expression.
(cfg
  feature-plain-comptime-well-known
  (defstruct MatchArm
    (pattern Pattern)
    (body Expr)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known MatchArm "v0")
    (defstruct MatchArm
      (pattern Pattern)
      (body Expr))))

;: Dense ordered sequence of generated match arms.
(cfg
  feature-plain-comptime-well-known
  (defstruct MatchArmList
    (items (Array MatchArm))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known MatchArmList "v0")
    (defstruct MatchArmList
      (items (Array MatchArm))
      (len i64))))

;: Dense ordered sequence of reflected type descriptors.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeInfoList
    (items (Array TypeInfo))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeInfoList "v0")
    (defstruct TypeInfoList
      (items (Array TypeInfo))
      (len i64))))

;: Reflected struct field name and type.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeField
    (name String)
    (ty TypeInfo)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeField "v0")
    (defstruct TypeField
      (name String)
      (ty TypeInfo))))

;: Dense ordered sequence of reflected struct fields.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeFieldList
    (items (Array TypeField))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeFieldList "v0")
    (defstruct TypeFieldList
      (items (Array TypeField))
      (len i64))))

;: Reflected enum variant payload type.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeVariantPayload
    (ty TypeInfo)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeVariantPayload "v0")
    (defstruct TypeVariantPayload
      (ty TypeInfo))))

;: Dense ordered sequence of reflected enum variant payloads.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeVariantPayloadList
    (items (Array TypeVariantPayload))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeVariantPayloadList "v0")
    (defstruct TypeVariantPayloadList
      (items (Array TypeVariantPayload))
      (len i64))))

;: Reflected enum variant name and payload list.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeVariant
    (name String)
    (payloads TypeVariantPayloadList)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeVariant "v0")
    (defstruct TypeVariant
      (name String)
      (payloads TypeVariantPayloadList))))

;: Dense ordered sequence of reflected enum variants.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeVariantList
    (items (Array TypeVariant))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeVariantList "v0")
    (defstruct TypeVariantList
      (items (Array TypeVariant))
      (len i64))))

;: Reflected nominal type parameter name and resolved type.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeParam
    (name String)
    (ty TypeInfo)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeParam "v0")
    (defstruct TypeParam
      (name String)
      (ty TypeInfo))))

;: Dense ordered sequence of reflected nominal type parameters.
(cfg
  feature-plain-comptime-well-known
  (defstruct TypeParamList
    (items (Array TypeParam))
    (len i64)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeParamList "v0")
    (defstruct TypeParamList
      (items (Array TypeParam))
      (len i64))))

;: Compile-time reflection descriptor for a TypeLisp type.
(cfg
  feature-plain-comptime-well-known
  (defenum TypeInfo
    (TypeInfoBuiltin String)
    (TypeInfoArray (Box TypeInfo) i64)
    (TypeInfoDynArray (Box TypeInfo))
    (TypeInfoFunction TypeInfoList (Box TypeInfo))
    (TypeInfoTuple TypeInfoList)
    (TypeInfoStruct String TypeFieldList)
    (TypeInfoEnum String TypeVariantList)
    (TypeInfoOpaque String)))

(cfg
  (not feature-plain-comptime-well-known)
  (comptime-decl
    (:generated stdlib/comptime-well-known TypeInfo "v0")
    (defenum TypeInfo
      (TypeInfoBuiltin String)
      (TypeInfoArray (Box TypeInfo) i64)
      (TypeInfoDynArray (Box TypeInfo))
      (TypeInfoFunction TypeInfoList (Box TypeInfo))
      (TypeInfoTuple TypeInfoList)
      (TypeInfoStruct String TypeFieldList)
      (TypeInfoEnum String TypeVariantList)
      (TypeInfoOpaque String))))

;: Build a bool literal expression during macro CTFE.
(define (expr-bool [value : bool]) : Expr
  (expr-bool value))

;: Build an integer literal expression during macro CTFE.
(define (expr-int [value : i64]) : Expr
  (expr-int value))

;: Build a string literal expression during macro CTFE.
(define (expr-string [value : String]) : Expr
  (expr-string value))

;: Build a variable-reference expression during macro CTFE.
(define (expr-var [name : String]) : Expr
  (expr-var name))

;: Build a struct field access expression during macro CTFE.
(define (expr-struct-get [target : Expr] [field : String]) : Expr
  (expr-struct-get target field))

;: Build a struct field assignment expression during macro CTFE.
(define (expr-struct-set [target : Expr] [field : String] [value : Expr]) : Expr
  (expr-struct-set target field value))

;: Concatenate two strings during macro CTFE.
(define (string-concat [left : String] [_right : String]) : String
  left)

;: Alias for `string-concat` during macro CTFE.
(define (string-append [left : String] [_right : String]) : String
  left)

;: Render an integer as a string during macro CTFE.
(define (int->string [_value : i64]) : String
  "")

;: Compiler-recognized compatibility entry for macro CTFE diagnostics.
;; lint-allow: redundant-function-name
(define (comptime-error [message : String]) : never
  (comptime-error message))

;: Abort macro CTFE with a source-located diagnostic.
(define (error [message : String]) : never
  (comptime-error message))

;: Mark an expression for unquote-splicing during macro CTFE.
(define (expr-splice [value : Expr]) : Expr
  (expr-splice value))

;: Build an if expression during macro CTFE.
(define (expr-if [cond : Expr] [then-expr : Expr] [else-expr : Expr]) : Expr
  (expr-if cond then-expr else-expr))

;: Build a wildcard match pattern during macro CTFE.
(define (pattern-wildcard) : Pattern
  (pattern-wildcard))

;: Build a match pattern that binds the scrutinee or payload to `name`.
(define (pattern-binding [name : String]) : Pattern
  (pattern-binding name))

;: Build an enum variant pattern by name and payload patterns.
(define (pattern-variant [name : String] [payloads : PatternList]) : Pattern
  (pattern-variant name payloads))

;: Build an empty pattern list.
(define (pattern-list-empty) : PatternList
  (pattern-list-empty))

;: Prepend a pattern to a pattern list.
(define (pattern-list-cons [head : Pattern] [tail : PatternList]) : PatternList
  (pattern-list-cons head tail))

;: Build a match arm from a generated pattern and result expression.
(define (match-arm [pattern : Pattern] [body : Expr]) : MatchArm
  (match-arm pattern body))

;: Build an empty match arm list.
(define (match-arm-list-empty) : MatchArmList
  (match-arm-list-empty))

;: Prepend a match arm to a match arm list.
(define (match-arm-list-cons [head : MatchArm] [tail : MatchArmList]) : MatchArmList
  (match-arm-list-cons head tail))

;: Build a match expression from a scrutinee expression and generated arms.
(define (expr-match [scrutinee : Expr] [arms : MatchArmList]) : Expr
  (expr-match scrutinee arms))

;: Return the produced type of a captured expression during macro CTFE.
(define (expr-type [value : Expr]) : Expr
  value)

;: Return the public value-level reflection descriptor for a type operand.
(define (type-info [ty : Expr]) : TypeInfo
  (type-info ty))

;: Return the canonical identity string for a module strategy operand.
(define (module-name [module : String]) : String
  module)

;: Return true when a module strategy exports a macro hook with `name`.
(define (module-export-macro? [_module : String] [_name : String]) : bool
  false)

;: Build an expression that calls a macro hook exported by a module strategy.
(define (module-hook [module : String] [name : String]) : Expr
  (expr-var (string-concat (string-concat module ".") name)))

;: Return true when an expression is a bool literal.
(define (expr-bool? [value : Expr]) : bool
  (match value
    [(ExprBool _) true]
    [_ false]))

;: Extract the bool literal payload from an expression.
(define (expr-bool-value [value : Expr]) : bool
  (match value
    [(ExprBool found) found]
    [_ false]))

;: Return true when an expression is an if expression.
(define (expr-if? [value : Expr]) : bool
  (match value
    [(ExprIf _ _ _) true]
    [_ false]))

;: Extract an if expression's condition.
(define (expr-if-cond [value : Expr]) : Expr
  (match value
    [(ExprIf cond _ _) cond]
    [_ value]))

;: Extract an if expression's then branch.
(define (expr-if-then [value : Expr]) : Expr
  (match value
    [(ExprIf _ then-expr _) then-expr]
    [_ value]))

;: Extract an if expression's else branch.
(define (expr-if-else [value : Expr]) : Expr
  (match value
    [(ExprIf _ _ else-expr) else-expr]
    [_ value]))

;: Return true when an expression list has no items.
(define (expr-list-empty? [items : ExprList]) : bool
  (expr-list-empty? items))

;: Return the number of items in an expression list.
(define (expr-list-length [items : ExprList]) : i64
  (expr-list-length items))

;: Return the first item in a non-empty expression list.
(define (expr-list-head [items : ExprList]) : Expr
  (expr-list-head items))

;: Return all but the first item from a non-empty expression list.
(define (expr-list-tail [items : ExprList]) : ExprList
  (expr-list-tail items))

;: Return an expression list item by index.
(define (expr-list-nth [items : ExprList] [index : i64]) : Expr
  (expr-list-nth items index))

;: Return the first expression from a clause.
(define (expr-clause-first [clause : ExprClause]) : Expr
  (match clause
    [(ExprClause first _) first]))

;: Return the second expression from a clause.
(define (expr-clause-second [clause : ExprClause]) : Expr
  (match clause
    [(ExprClause _ second) second]))

;: Return true when a clause list has no items.
(define (expr-clause-list-empty? [items : ExprClauseList]) : bool
  (expr-clause-list-empty? items))

;: Return the number of clauses in a clause list.
(define (expr-clause-list-length [items : ExprClauseList]) : i64
  (expr-clause-list-length items))

;: Return the first item in a non-empty clause list.
(define (expr-clause-list-head [items : ExprClauseList]) : ExprClause
  (expr-clause-list-head items))

;: Return all but the first item from a non-empty clause list.
(define (expr-clause-list-tail [items : ExprClauseList]) : ExprClauseList
  (expr-clause-list-tail items))

;: Return a clause list item by index.
(define (expr-clause-list-nth [items : ExprClauseList] [index : i64]) : ExprClause
  (expr-clause-list-nth items index))

;: Convert clause first expressions into an expression list.
(define (expr-clause-list->expr-list [items : ExprClauseList]) : ExprList
  (expr-clause-list->expr-list items))

;: Return the user-facing binding name from a binding clause.
(define (expr-binding-clause-name [clause : ExprBindingClause]) : String
  (expr-binding-clause-name clause))

;: Return true when a binding clause includes an explicit type annotation.
(define (expr-binding-clause-has-type? [clause : ExprBindingClause]) : bool
  (expr-binding-clause-has-type? clause))

;: Return the explicit type annotation syntax from a typed binding clause.
(define (expr-binding-clause-type [clause : ExprBindingClause]) : Expr
  (expr-binding-clause-type clause))

;: Return the initializer expression from a binding clause.
(define (expr-binding-clause-init [clause : ExprBindingClause]) : Expr
  (expr-binding-clause-init clause))

;: Return true when a binding-clause list has no items.
(define (expr-binding-clause-list-empty? [items : ExprBindingClauseList]) : bool
  (expr-binding-clause-list-empty? items))

;: Return the number of binding clauses in a binding-clause list.
(define (expr-binding-clause-list-length [items : ExprBindingClauseList]) : i64
  (expr-binding-clause-list-length items))

;: Return the first item in a non-empty binding-clause list.
(define (expr-binding-clause-list-head [items : ExprBindingClauseList]) : ExprBindingClause
  (expr-binding-clause-list-head items))

;: Return all but the first item from a non-empty binding-clause list.
(define (expr-binding-clause-list-tail [items : ExprBindingClauseList]) : ExprBindingClauseList
  (expr-binding-clause-list-tail items))

;: Return a binding-clause list item by index.
(define (expr-binding-clause-list-nth
  [items : ExprBindingClauseList]
  [index : i64]) : ExprBindingClause
  (expr-binding-clause-list-nth items index))

;: Convert binding clauses back into bracket-clause operand syntax.
(define (expr-binding-clause-list->expr-list [items : ExprBindingClauseList]) : ExprList
  (expr-binding-clause-list->expr-list items))