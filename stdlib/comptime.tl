;# Public compile-time syntax and reflection surface.
;#
;# This module owns the stdlib-side declarations for the well-known comptime
;# types described by SPEC 3.7.2.2. The current compiler still stores macro
;# syntax internally as `AstTyExpr` / `CtfeExpr`; it verifies these declarations
;# and treats the syntax types as aliases for that internal representation while
;# the CTFE value migration lands. The helper functions below are stdlib-owned
;# signatures for the same compile-time-only bridge; macro CTFE intercepts calls
;# to them before their placeholder bodies are evaluated.
(module stdlib.comptime)

;: Syntax value passed to and returned from expression macros.
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
    (ExprUnquoteSplicing (Box Expr))))

;: Dense ordered sequence of syntax expressions.
(comptime-decl
  (:generated stdlib/comptime-well-known ExprList "v0")
  (defstruct ExprList
    (items (Array Expr))
    (len i64)))

;: Pair of expressions used by clause-oriented macro forms.
(comptime-decl
  (:generated stdlib/comptime-well-known ExprClause "v0")
  (defstruct ExprClause
    (first Expr)
    (second Expr)))

;: Dense ordered sequence of expression clauses.
(comptime-decl
  (:generated stdlib/comptime-well-known ExprClauseList "v0")
  (defstruct ExprClauseList
    (items (Array ExprClause))
    (len i64)))

;: Dense ordered sequence of reflected type descriptors.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeInfoList "v0")
  (defstruct TypeInfoList
    (items (Array TypeInfo))
    (len i64)))

;: Reflected struct field name and type.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeField "v0")
  (defstruct TypeField
    (name String)
    (ty TypeInfo)))

;: Dense ordered sequence of reflected struct fields.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeFieldList "v0")
  (defstruct TypeFieldList
    (items (Array TypeField))
    (len i64)))

;: Reflected enum variant payload type.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeVariantPayload "v0")
  (defstruct TypeVariantPayload
    (ty TypeInfo)))

;: Dense ordered sequence of reflected enum variant payloads.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeVariantPayloadList "v0")
  (defstruct TypeVariantPayloadList
    (items (Array TypeVariantPayload))
    (len i64)))

;: Reflected enum variant name and payload list.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeVariant "v0")
  (defstruct TypeVariant
    (name String)
    (payloads TypeVariantPayloadList)))

;: Dense ordered sequence of reflected enum variants.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeVariantList "v0")
  (defstruct TypeVariantList
    (items (Array TypeVariant))
    (len i64)))

;: Reflected nominal type parameter name and resolved type.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeParam "v0")
  (defstruct TypeParam
    (name String)
    (ty TypeInfo)))

;: Dense ordered sequence of reflected nominal type parameters.
(comptime-decl
  (:generated stdlib/comptime-well-known TypeParamList "v0")
  (defstruct TypeParamList
    (items (Array TypeParam))
    (len i64)))

;: Compile-time reflection descriptor for a TypeLisp type.
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
    (TypeInfoOpaque String)))

;: Build a bool literal expression during macro CTFE.
(define (expr-bool [value : bool]) : Expr
  (expr-bool value))

;: Build an integer literal expression during macro CTFE.
(define (expr-int [value : i64]) : Expr
  (expr-int value))

;: Build a variable-reference expression during macro CTFE.
(define (expr-var [name : String]) : Expr
  (expr-var name))

;: Concatenate two strings during macro CTFE.
(define (string-concat [left : String] [_right : String]) : String
  left)

;: Alias for `string-concat` during macro CTFE.
(define (string-append [left : String] [_right : String]) : String
  left)

;: Render an integer as a string during macro CTFE.
(define (int->string [_value : i64]) : String
  "")

;: Mark an expression for unquote-splicing during macro CTFE.
(define (expr-splice [value : Expr]) : Expr
  (expr-splice value))

;: Build an if expression during macro CTFE.
(define (expr-if [cond : Expr] [then-expr : Expr] [else-expr : Expr]) : Expr
  (expr-if cond then-expr else-expr))

;: Return the produced type of a captured expression during macro CTFE.
(define (expr-type [value : Expr]) : Expr
  value)

;: Return true when an expression is a bool literal.
(define (expr-bool? [value : Expr]) : bool
  (expr-bool? value))

;: Extract the bool literal payload from an expression.
(define (expr-bool-value [value : Expr]) : bool
  (expr-bool-value value))

;: Return true when an expression is an if expression.
(define (expr-if? [value : Expr]) : bool
  (expr-if? value))

;: Extract an if expression's condition.
(define (expr-if-cond [value : Expr]) : Expr
  (expr-if-cond value))

;: Extract an if expression's then branch.
(define (expr-if-then [value : Expr]) : Expr
  (expr-if-then value))

;: Extract an if expression's else branch.
(define (expr-if-else [value : Expr]) : Expr
  (expr-if-else value))

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
  (expr-clause-first clause))

;: Return the second expression from a clause.
(define (expr-clause-second [clause : ExprClause]) : Expr
  (expr-clause-second clause))

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

(export
  (type Expr)
  (variant ExprBool)
  (variant ExprInt)
  (variant ExprVar)
  (variant ExprSplice)
  (variant ExprIf)
  (variant ExprCall)
  (variant ExprBegin)
  (variant ExprQuote)
  (variant ExprQuasiquote)
  (variant ExprUnquote)
  (variant ExprUnquoteSplicing)
  (type ExprList)
  (constructor ExprList)
  (field ExprList items)
  (field ExprList len)
  (type ExprClause)
  (constructor ExprClause)
  (field ExprClause first)
  (field ExprClause second)
  (type ExprClauseList)
  (constructor ExprClauseList)
  (field ExprClauseList items)
  (field ExprClauseList len)
  (type TypeInfoList)
  (constructor TypeInfoList)
  (field TypeInfoList items)
  (field TypeInfoList len)
  (type TypeField)
  (constructor TypeField)
  (field TypeField name)
  (field TypeField ty)
  (type TypeFieldList)
  (constructor TypeFieldList)
  (field TypeFieldList items)
  (field TypeFieldList len)
  (type TypeVariantPayload)
  (constructor TypeVariantPayload)
  (field TypeVariantPayload ty)
  (type TypeVariantPayloadList)
  (constructor TypeVariantPayloadList)
  (field TypeVariantPayloadList items)
  (field TypeVariantPayloadList len)
  (type TypeVariant)
  (constructor TypeVariant)
  (field TypeVariant name)
  (field TypeVariant payloads)
  (type TypeVariantList)
  (constructor TypeVariantList)
  (field TypeVariantList items)
  (field TypeVariantList len)
  (type TypeParam)
  (constructor TypeParam)
  (field TypeParam name)
  (field TypeParam ty)
  (type TypeParamList)
  (constructor TypeParamList)
  (field TypeParamList items)
  (field TypeParamList len)
  (type TypeInfo)
  (variant TypeInfoBuiltin)
  (variant TypeInfoArray)
  (variant TypeInfoDynArray)
  (variant TypeInfoFunction)
  (variant TypeInfoTuple)
  (variant TypeInfoStruct)
  (variant TypeInfoEnum)
  (variant TypeInfoOpaque)
  (value expr-bool)
  (value expr-int)
  (value expr-var)
  (value string-concat)
  (value string-append)
  (value int->string)
  (value expr-splice)
  (value expr-if)
  (value expr-type)
  (value expr-bool?)
  (value expr-bool-value)
  (value expr-if?)
  (value expr-if-cond)
  (value expr-if-then)
  (value expr-if-else)
  (value expr-list-empty?)
  (value expr-list-length)
  (value expr-list-head)
  (value expr-list-tail)
  (value expr-list-nth)
  (value expr-clause-first)
  (value expr-clause-second)
  (value expr-clause-list-empty?)
  (value expr-clause-list-length)
  (value expr-clause-list-head)
  (value expr-clause-list-tail)
  (value expr-clause-list-nth)
  (value expr-clause-list->expr-list))