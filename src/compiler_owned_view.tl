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

;; A non-reference operand is a Copy part already bound by value through a
;; shared reference (SPEC section 5.13); its copy is its own view.
(defmacro (compiler-owned-reference-shared-view [reference : Expr]) : Expr
  (let
    [reference-ty : comptime.Expr (comptime.expr-type reference)]
    [reference-kind : String (type-kind reference-ty)]
    (if (if (string.eq reference-kind "ref")
      false
      (if (string.eq reference-kind "mut-ref")
        false
        true))
      reference
      (let
        [value-ty : comptime.Expr
          (comptime.reference-element-type reference-ty)]
        (match (comptime.type-info value-ty)
          [(comptime.TypeInfo.DynArray _)
            `(unsafe
              (ptr-read
                (ptr-cast
                  (__tl_array-data (array ,reference))
                  : (Ptr ,value-ty))))]
          [(comptime.TypeInfo.Builtin kind)
            (if (string.eq kind "string")
              `(unsafe
                (ptr-read
                  (ptr-cast
                    (__tl_array-data (array ,reference))
                    : (Ptr ,value-ty))))
              `(let
                [address : u64
                  (unsafe
                    (ptr-read
                      (ptr-cast
                        (__tl_array-data (array ,reference))
                        : (Ptr u64))))]
                (unsafe
                  (ptr-read (int->ptr address : (Ptr ,value-ty))))))]
          [_
            `(let
              [address : u64
                (unsafe
                  (ptr-read
                    (ptr-cast (__tl_array-data (array ,reference)) : (Ptr u64))))]
              (unsafe
                (ptr-read (int->ptr address : (Ptr ,value-ty)))))])))))

(defmacro (compiler-owned-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

(defmacro (compiler-owned-string-place-shared-view [place : Expr]) : Expr
  `(let
    [shared-ref (& ,place)]
    (unsafe
      (ptr-read (ptr-cast (__tl_array-data (array shared-ref)) : (Ptr String))))))

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

;; A value that is not a Box is already the boxed value: a `(Box T)` payload
;; matched through a shared reference binds `(& T)` (SPEC section 5.13).
(defmacro (compiler-owned-box-shared-view [value : Expr]) : Expr
  (let
    [value-ty : comptime.Expr (comptime.expr-type value)]
    (if (string-eq (type-kind value-ty) "box")
      `(compiler-owned-typed-box-shared-view
        ,value
        ,(comptime.box-element-type value-ty))
      value)))

;; Pattern-binding bridges for the bootstrap seed. A name bound by a pattern
;; matched through a shared reference binds a Copy part by value and a `(Box T)`
;; part as `(& T)` (SPEC section 5.13); a seed published before that rule binds
;; `(& T)` and `(& (Box T))`. Compiler sources compiled by both read such
;; bindings through these macros until the seed carries the rule, then use the
;; binding directly.
;; The value of a Copy part bound through a shared reference: `(deref binding)`
;; when the binding is a reference or a box, the binding itself otherwise.
(defmacro (compiler-owned-pattern-copy [binding : Expr]) : Expr
  (let
    [kind : String (type-kind (comptime.expr-type binding))]
    (if (if (string.eq kind "ref")
      true
      (string.eq kind "box"))
      `(deref ,binding)
      binding)))

;; A shared reference to the boxed `T` of a `(Box T)` part bound through a
;; shared reference.
(defmacro (compiler-owned-pattern-box-ref [binding : Expr]) : Expr
  (let
    [binding-ty : comptime.Expr (comptime.expr-type binding)]
    (if (if (string.eq (type-kind binding-ty) "ref")
      (string.eq (type-kind (comptime.reference-element-type binding-ty)) "box")
      false)
      `(& (deref (deref ,binding)))
      binding)))