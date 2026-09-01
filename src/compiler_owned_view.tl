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

(defmacro (compiler-owned-reference-shared-view [reference : Expr]) : Expr
  (let
    [value-ty : comptime.Expr
      (comptime.reference-element-type (comptime.expr-type reference))]
    (match (comptime.type-info value-ty)
      [(comptime.TypeInfo.DynArray _)
        `(__tl-compiler-owned-shared-view-dyn-ref-as ,reference ,value-ty)]
      [(comptime.TypeInfo.Builtin kind)
        (if (string.eq kind "string")
          `(__tl-compiler-owned-shared-view-dyn-ref-as ,reference ,value-ty)
          `(let
            [address : u64
              (unsafe
                (ptr-read
                  (ptr-cast (__tl_array-data (array ,reference)) : (Ptr u64))))]
            (unsafe
              (ptr-read (int->ptr address : (Ptr ,value-ty))))))]
      [_
        `(let
          [address : u64
            (unsafe
              (ptr-read
                (ptr-cast (__tl_array-data (array ,reference)) : (Ptr u64))))]
          (unsafe
            (ptr-read (int->ptr address : (Ptr ,value-ty)))))])))

(defmacro (compiler-owned-shared-view [place : Expr]) : Expr
  (cfg
    stage0-borrowed-inline-bootstrap
    (let
      [value-ty : comptime.Expr (comptime.expr-type place)]
      [region? : bool (string.eq (type-kind value-ty) "region")]
      (match (comptime.type-info value-ty)
        [(comptime.TypeInfo.DynArray _)
          (if region?
            `(let
              [shared-ref (& ,place)]
              (compiler-owned-reference-shared-view shared-ref))
            `(let
              [shared-ref (& ,place)]
              (__tl-compiler-owned-shared-view-dyn-ref-as shared-ref ,value-ty)))]
        [(comptime.TypeInfo.Builtin kind)
          (if region?
            `(let
              [shared-ref (& ,place)]
              (compiler-owned-reference-shared-view shared-ref))
            (if (string.eq kind "string")
              `(let
                [shared-ref (& ,place)]
                (__tl-compiler-owned-shared-view-dyn-ref-as
                  shared-ref
                  ,value-ty))
              place))]
        [(comptime.TypeInfo.Opaque _)
          (if region?
            `(let
              [shared-ref (& ,place)]
              (compiler-owned-reference-shared-view shared-ref))
            `(unsafe
              (ptr-read (ptr-addr-of ,place))))]
        [_
          (if region?
            `(let
              [shared-ref (& ,place)]
              (compiler-owned-reference-shared-view shared-ref))
            `(unsafe
              (ptr-read (ptr-addr-of ,place))))]))
    `(unsafe
      (ptr-read (ptr-addr-of ,place)))))

(defmacro (compiler-owned-string-place-shared-view [place : Expr]) : Expr
  `(let
    [shared-ref (& ,place)]
    (__tl-compiler-owned-shared-view-dyn-ref-as shared-ref String)))

;; Global and ordinary local places keep the direct shallow load used by the
;; bootstrap. A projected place rooted in an explicit reference is lifetime-
;; tagged as `region`; route only that case through the reference-cell bridge.
(defmacro (compiler-owned-place-shared-view [place : Expr]) : Expr
  (let
    [value-ty : comptime.Expr (comptime.expr-type place)]
    (match (comptime.type-info value-ty)
      [(comptime.TypeInfo.Builtin kind)
        (if (string.eq kind "string")
          `(unsafe
            (ptr-read (ptr-addr-of ,place)))
          place)]
      [_
        (if (string.eq (type-kind value-ty) "region")
          `(compiler-owned-shared-view ,place)
          `(unsafe
            (ptr-read (ptr-addr-of ,place))))])))

(defmacro (compiler-owned-array-element-shared-view
  [items : Expr]
  [index : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-offset (__tl_array-data ,items) ,index))))

(defmacro (compiler-owned-typed-box-shared-view
  [value : Expr]
  ;; Spliced into the generated pointer element type.
  ;; lint-allow: unused-variable
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