;# Public compile-time syntax and reflection surface.
;#
;# This module owns the stdlib-side declarations for the well-known comptime
;# types described by SPEC 3.7.2.2. The current compiler still stores macro
;# syntax internally as `AstTyExpr` / `CtfeExpr`; it verifies these declarations
;# and treats the syntax types as aliases for that internal representation while
;# the CTFE value migration lands.
(module stdlib.comptime)

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

(comptime-decl
  (:generated stdlib/comptime-well-known ExprList "v0")
  (defstruct ExprList
    (items (Array Expr))
    (len i64)))

(comptime-decl
  (:generated stdlib/comptime-well-known ExprClause "v0")
  (defstruct ExprClause
    (first Expr)
    (second Expr)))

(comptime-decl
  (:generated stdlib/comptime-well-known ExprClauseList "v0")
  (defstruct ExprClauseList
    (items (Array ExprClause))
    (len i64)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeInfoList "v0")
  (defstruct TypeInfoList
    (items (Array TypeInfo))
    (len i64)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeField "v0")
  (defstruct TypeField
    (name String)
    (ty TypeInfo)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeFieldList "v0")
  (defstruct TypeFieldList
    (items (Array TypeField))
    (len i64)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeVariantPayload "v0")
  (defstruct TypeVariantPayload
    (ty TypeInfo)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeVariantPayloadList "v0")
  (defstruct TypeVariantPayloadList
    (items (Array TypeVariantPayload))
    (len i64)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeVariant "v0")
  (defstruct TypeVariant
    (name String)
    (payloads TypeVariantPayloadList)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeVariantList "v0")
  (defstruct TypeVariantList
    (items (Array TypeVariant))
    (len i64)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeParam "v0")
  (defstruct TypeParam
    (name String)
    (ty TypeInfo)))

(comptime-decl
  (:generated stdlib/comptime-well-known TypeParamList "v0")
  (defstruct TypeParamList
    (items (Array TypeParam))
    (len i64)))

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
  (variant TypeInfoOpaque))