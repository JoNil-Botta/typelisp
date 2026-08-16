;; compiler_owned_view.tl - Internal shallow views for the by-value ownership cutover.
;;
;; Ordinary TypeLisp value parameters own their arguments. Compiler subsystems
;; often keep arena-backed aggregate owners while passing read-only views through
;; existing by-value helper APIs; these macros make that representation-level
;; read explicit without performing a deep clone. They are migration scaffolding:
;; public APIs should still use `&`/`&mut` when a checked borrow is part of their
;; contract.
(import stdlib.comptime)
(import stdlib.string)

(defmacro (compiler-owned-shared-view [place : Expr]) : Expr
  (let
    [value-ty : comptime.Expr (comptime.expr-type place)]
    (match (comptime.type-info value-ty)
      [(comptime.TypeInfo.DynArray _)
        `(let
          [shared-ref (& ,place)]
          (__tl-compiler-owned-shared-view-dyn-ref-as shared-ref ,value-ty))]
      [(comptime.TypeInfo.Builtin kind)
        (if (string.eq kind "string")
          `(let
            [shared-ref (& ,place)]
            (__tl-compiler-owned-shared-view-dyn-ref-as shared-ref ,value-ty))
          `(unsafe
            (ptr-read (ptr-addr-of ,place))))]
      [_
        `(unsafe
          (ptr-read (ptr-addr-of ,place)))])))

(defmacro (compiler-owned-array-element-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (array-data ,items) ,index))))

(defmacro (compiler-owned-typed-box-shared-view
  [value : Expr]
  [value-ty : Expr]) : Expr
  `(let
    [address : u64
      (unsafe
        (ptr-read (ptr-cast (ptr-addr-of ,value) : (Ptr u64))))]
    (unsafe
      (ptr-read (int->ptr address : (Ptr ,value-ty))))))

(defmacro (compiler-owned-box-shared-view [value : Expr]) : Expr
  (let
    [inner-ty : comptime.Expr
      (comptime.box-element-type (comptime.expr-type value))]
    `(compiler-owned-typed-box-shared-view ,value ,inner-ty)))