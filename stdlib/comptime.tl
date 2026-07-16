;# Public compile-time syntax and reflection surface.
;#
;# This module owns the stdlib-side declarations for the well-known comptime
;# types described by SPEC 3.7.2.2. The compiler stores macro
;# syntax internally as `AstType.Expr` / `CompilerCtfeValue.Expr`; it verifies these declarations
;# and treats the syntax types as aliases for that internal representation.
;#
;# CTFE still intercepts constructors, reflection helpers, and sequence
;# operations that must rebuild provenance-carrying syntax, because it cannot yet
;# interpret arbitrary stdlib function calls and several constructors attach
;# compiler provenance. Simple `Expr`/`ExprClause` inspectors and dense sequence
;# accessors below are ordinary source bodies so macro code can migrate toward
;# public field and array access without growing the bridge surface.
;: Syntax value passed to and returned from expression macros.
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
  (ExprUnquoteSplicing (Box Expr)))

;: Dense ordered sequence of syntax expressions.
(defstruct ExprList
  (items (Array Expr))
  (len i64))

;: Pair of expressions used by clause-oriented macro forms.
(defstruct ExprClause
  (first Expr)
  (second Expr))

;: Dense ordered sequence of expression clauses.
(defstruct ExprClauseList
  (items (Array ExprClause))
  (len i64))

;: Let-like binding clause used by binding-introducing macro forms.
(defstruct ExprBindingClause
  (name String)
  (has-type bool)
  (ty Expr)
  (init Expr))

;: Dense ordered sequence of binding clauses.
(defstruct ExprBindingClauseList
  (items (Array ExprBindingClause))
  (len i64))

;: Match pattern syntax value built during macro CTFE.
(defenum Pattern
  (PatternWildcard)
  (PatternBinding String)
  (PatternVariant String PatternList))

;: Dense ordered sequence of match pattern syntax values.
(defstruct PatternList
  (items (Array Pattern))
  (len i64))

;: Generated match arm made from a pattern and result expression.
(defstruct MatchArm
  (pattern Pattern)
  (body Expr))

;: Dense ordered sequence of generated match arms.
(defstruct MatchArmList
  (items (Array MatchArm))
  (len i64))

;: Dense ordered sequence of reflected type descriptors.
(defstruct TypeInfoList
  (items (Array TypeInfo))
  (len i64))

;: Reflected struct field name and type.
(defstruct TypeField
  (name String)
  (ty TypeInfo))

;: Dense ordered sequence of reflected struct fields.
(defstruct TypeFieldList
  (items (Array TypeField))
  (len i64))

;: Reflected enum variant payload type.
(defstruct TypeVariantPayload
  (ty TypeInfo))

;: Dense ordered sequence of reflected enum variant payloads.
(defstruct TypeVariantPayloadList
  (items (Array TypeVariantPayload))
  (len i64))

;: Reflected enum variant name and payload list.
(defstruct TypeVariant
  (name String)
  (payloads TypeVariantPayloadList))

;: Dense ordered sequence of reflected enum variants.
(defstruct TypeVariantList
  (items (Array TypeVariant))
  (len i64))

;: Reflected nominal type parameter name and resolved type.
(defstruct TypeParam
  (name String)
  (ty TypeInfo))

;: Dense ordered sequence of reflected nominal type parameters.
(defstruct TypeParamList
  (items (Array TypeParam))
  (len i64))

;: Compile-time reflection descriptor for a TypeLisp type.
(defenum TypeInfo
  (TypeInfoBuiltin String)
  (TypeInfoArray (Box TypeInfo) i64)
  (TypeInfoDynArray (Box TypeInfo))
  (TypeInfoFunction TypeInfoList (Box TypeInfo))
  (TypeInfoTuple TypeInfoList)
  (TypeInfoStruct String TypeFieldList)
  (TypeInfoEnum String TypeVariantList)
  (TypeInfoOpaque String))

;: Build a bool literal expression during macro CTFE.
(define (expr-bool [value : bool]) : Expr
  (expr-bool value))

;: Build an integer literal expression during macro CTFE.
(define (expr-int [value : i64]) : Expr
  (expr-int value))

;: Build a string literal expression during macro CTFE.
(define (expr-string [value : String]) : Expr
  (expr-string value))

;: Build an opaque binary-data expression from compile-time bytes.
;:
;: The expanded expression has type `(Array u8)` and lowers directly to static
;: binary data, without constructing or parsing an array literal.
(define (expr-binary-data [value : String]) : Expr
  (expr-binary-data value))

;: Return true when a captured expression is a string literal.
;:
;: This compile-time-only syntax inspector distinguishes caller literals from
;: expressions that merely produce `String`, without exposing compiler AST
;: internals.
(define (expr-string? [_value : Expr]) : bool
  false)

;: Extract a captured string literal's bytes during macro CTFE.
;:
;: Calling this for a non-literal expression reports a source-located
;: compile-time diagnostic. The fallback body keeps bootstrap source valid;
;: the compiler preserves captured-literal provenance.
(define (expr-string-value [_value : Expr]) : String
  "")

;: Build a variable-reference expression during macro CTFE.
(define (expr-var [name : String]) : Expr
  (expr-var name))

;: Build a struct field access expression during macro CTFE.
(define (expr-struct-get [target : Expr] [field : String]) : Expr
  (expr-struct-get target field))

;: Build a tuple element access expression during macro CTFE.
(define (expr-tuple-ref [target : Expr] [index : i64]) : Expr
  (expr-tuple-ref target index))

;: Build a struct field assignment expression during macro CTFE.
(define (expr-struct-set [target : Expr] [field : String] [value : Expr]) : Expr
  (expr-struct-set target field value))

;: Build an explicit inferred-lifetime mutable borrow expression during macro CTFE.
;: The expanded program validates that `place` is a mutable borrowable place.
(define (expr-mut-borrow [place : Expr]) : Expr
  (expr-mut-borrow place))

;: Build an ordered empty expression argument list during macro CTFE.
(define (expr-list-empty) : ExprList
  (expr-list-empty))

;: Prepend `head` to an ordered expression argument list during macro CTFE.
(define (expr-list-cons [head : Expr] [tail : ExprList]) : ExprList
  (expr-list-cons head tail))

;: Build an ordinary call expression from a callee expression and ordered arguments.
(define (expr-call [callee : Expr] [args : ExprList]) : Expr
  (expr-call callee args))

;: Build a call with an inferred mutable borrow of `place` and no other arguments.
(define (expr-mut-call0 [callee : Expr] [place : Expr]) : Expr
  (expr-mut-call0 callee place))

;: Build a call with an inferred mutable borrow of `place` and one argument.
(define (expr-mut-call1 [callee : Expr] [place : Expr] [arg : Expr]) : Expr
  (expr-mut-call1 callee place arg))

;: Build a call with an inferred mutable borrow of `place` and two arguments.
(define (expr-mut-call2
  [callee : Expr]
  [place : Expr]
  [first : Expr]
  [second : Expr]) : Expr
  (expr-mut-call2 callee place first second))

;: Concatenate two strings during macro CTFE.
(define (string-concat [left : String] [_right : String]) : String
  left)

;: Alias for `string-concat` during macro CTFE.
(define (string-append [left : String] [_right : String]) : String
  left)

;: Extract a byte range from a comptime string during macro CTFE.
;:
;: Bounds use the `[start, start + len)` contract of `string.substring`.
(define (string-slice [text : String] [_start : i64] [_len : i64]) : String
  text)

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

;: Build a right-associated conditional chain from an expression sequence.
;:
;: Each sequence item becomes an `if` condition. `when-true` and `when-false`
;: are the terminal branches; `continue-on-true` selects whether the accumulated
;: suffix is placed in the true branch (`true`) or false branch (`false`). This
;: lets user macros construct iterative short-circuit syntax without recursively
;: emitting more macro calls.
(define (expr-list-fold-if
  [items : ExprList]
  [when-true : Expr]
  [when-false : Expr]
  [continue-on-true : bool]) : Expr
  (expr-list-fold-if items when-true when-false continue-on-true))

;: Build a right-associated conditional chain from expression clauses.
;:
;: The final `[else result]` supplies the initial result. A non-`else` final
;: clause yields `missing-final`; an `else` before the final clause yields
;: `else-not-final`. Other clauses become `(if test result suffix)`. This is a
;: sequence primitive, so user macros can construct conditional chains without
;: recursively emitting macro calls.
(define (expr-clause-list-fold-if
  [items : ExprClauseList]
  [missing-final : Expr]
  [else-not-final : Expr]) : Expr
  (expr-clause-list-fold-if items missing-final else-not-final))

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

;: Build `count` binding patterns named `prefix0` through `prefix<count - 1>`.
(define (pattern-list-bindings [prefix : String] [count : i64]) : PatternList
  (pattern-list-bindings prefix count))

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

;: Return the number of items in an expression list.
(define (expr-list-length [items : ExprList]) : i64
  (struct-get items len))

;: Return an expression list item by index.
(define (expr-list-nth [items : ExprList] [index : i64]) : Expr
  (if (< index 0)
    (comptime-error "expr-list-nth index out of range")
    (if (>= index (struct-get items len))
      (comptime-error "expr-list-nth index out of range")
      (__tl_array-ref (struct-get items items) index))))

;: Return the first expression from a clause.
(define (expr-clause-first [clause : ExprClause]) : Expr
  (match clause
    [(ExprClause first _) first]))

;: Return the second expression from a clause.
(define (expr-clause-second [clause : ExprClause]) : Expr
  (match clause
    [(ExprClause _ second) second]))

;: Return the number of clauses in a clause list.
(define (expr-clause-list-length [items : ExprClauseList]) : i64
  (struct-get items len))

;: Return a clause list item by index.
(define (expr-clause-list-nth [items : ExprClauseList] [index : i64]) : ExprClause
  (if (< index 0)
    (comptime-error "expr-clause-list-nth index out of range")
    (if (>= index (struct-get items len))
      (comptime-error "expr-clause-list-nth index out of range")
      (__tl_array-ref (struct-get items items) index))))

;: Convert clause first expressions into an expression list.
;: This remains intrinsic because conversion rebuilds bracket-clause syntax
;: expressions with compiler-owned provenance.
(define (expr-clause-list->expr-list [items : ExprClauseList]) : ExprList
  (expr-clause-list->expr-list items))

;: Return the user-facing binding name from a binding clause.
(define (expr-binding-clause-name [clause : ExprBindingClause]) : String
  (struct-get clause name))

;: Return true when a binding clause includes an explicit type annotation.
(define (expr-binding-clause-has-type? [clause : ExprBindingClause]) : bool
  (struct-get clause has-type))

;: Return the explicit type annotation syntax from a typed binding clause.
(define (expr-binding-clause-type [clause : ExprBindingClause]) : Expr
  (struct-get clause ty))

;: Return the initializer expression from a binding clause.
(define (expr-binding-clause-init [clause : ExprBindingClause]) : Expr
  (struct-get clause init))

;: Return the number of binding clauses in a binding-clause list.
(define (expr-binding-clause-list-length [items : ExprBindingClauseList]) : i64
  (struct-get items len))

;: Return a binding-clause list item by index.
(define (expr-binding-clause-list-nth
  [items : ExprBindingClauseList]
  [index : i64]) : ExprBindingClause
  (if (< index 0)
    (comptime-error "expr-binding-clause-list-nth index out of range")
    (if (>= index (struct-get items len))
      (comptime-error "expr-binding-clause-list-nth index out of range")
      (__tl_array-ref (struct-get items items) index))))

;: Convert binding clauses back into bracket-clause operand syntax.
;: This remains intrinsic because conversion rebuilds bracket-clause syntax
;: expressions with compiler-owned provenance.
(define (expr-binding-clause-list->expr-list [items : ExprBindingClauseList]) : ExprList
  (expr-binding-clause-list->expr-list items))