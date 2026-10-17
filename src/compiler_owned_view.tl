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
(import compiler_abort as abort)

;; A non-reference operand is a Copy part already bound by value through a
;; shared reference (SPEC section 5.13); its copy is its own view.
;;
;; The reference is stored in a one-element array cell and read back through
;; the cell's data pointer. A dynamic array or string reference carries the
;; handle itself; any other reference carries the referent's address.
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
              `(unsafe
                (ptr-read
                  (ptr-read
                    (ptr-cast
                      (__tl_array-data (array ,reference))
                      : (Ptr (Ptr ,value-ty)))))))]
          [_
            `(unsafe
              (ptr-read
                (ptr-read
                  (ptr-cast
                    (__tl_array-data (array ,reference))
                    : (Ptr (Ptr ,value-ty))))))])))))

(defmacro (compiler-owned-shared-view [place : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-addr-of ,place))))

;; An explicit write into a dynamic-array cell reached through a shared
;; reference: caches and memo cells inside shared compiler state are interior-
;; mutable. The store is bounds-checked; the aliasing is the caller's contract
;; (safe code cannot write through `&` otherwise). Only for `__tl_dyn-array`
;; cells, whose by-value view shares their storage.
(defmacro (compiler-owned-cell-set!
  [cells : Expr]
  [index : Expr]
  [value : Expr]) : Expr
  `(let
    [owned-cells (compiler-owned-reference-shared-view (& ,cells))]
    (set! (array-ref owned-cells ,index) ,value)))

;; An explicit write into a box cell reached through a shared reference, as
;; `compiler-owned-cell-set!` writes a dynamic-array cell: the box's by-value
;; view shares its contents. The aliasing is the caller's contract.
(defmacro (compiler-owned-box-cell-set! [cell : Expr] [value : Expr]) : Expr
  `(let
    [owned-box (compiler-owned-reference-shared-view (& ,cell))]
    (set! (deref owned-box) ,value)))

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

;; A representation copy of `items[index]`, read in place: the index is checked
;; against the array length (aborting like an out-of-bounds `array-ref`), then
;; the element is read bitwise, so the array keeps owning it. `items` is an
;; array place or a reference to one; an array place is evaluated twice.
(defmacro (compiler-owned-element-view [items : Expr] [index : Expr]) : Expr
  (let
    [items-kind : String (type-kind (comptime.expr-type items))]
    (if (if (string.eq items-kind "ref")
      true
      (string.eq items-kind "mut-ref"))
      `(let
        [element-index : i64 ,index]
        [element-items (compiler-owned-reference-shared-view ,items)]
        (unsafe
          (when
            (or
              (< element-index 0)
              (>= element-index (array-length element-items)))
            (abort.compiler-abort "array index out of bounds in element view\n"))
          (ptr-read (ptr-offset (__tl_array-data element-items) element-index))))
      ;; An array place (possibly a field reached through a shared reference)
      ;; is only read in place, its length and then one element: it is never
      ;; moved out.
      `(let
        [element-index : i64 ,index]
        (unsafe
          (when
            (or (< element-index 0) (>= element-index (array-length ,items)))
            (abort.compiler-abort "array index out of bounds in element view\n"))
          (ptr-read (ptr-offset (__tl_array-data ,items) element-index)))))))

(defmacro (compiler-owned-typed-box-shared-view
  [value : Expr]
  ;; Spliced into the generated pointer element type.
  ;; lint-allow: unused-variable
  [value-ty : Expr]
  [fields : Expr ...]) : Expr
  (let
    [count : i64 (comptime.expr-list-length fields)]
    (if (> count 1)
      (comptime.error "box view accepts at most one field selector")
      unit)
    (if (= count 0)
      `(let
        [address : u64
          (unsafe
            (ptr-read (ptr-cast (ptr-addr-of ,value) : (Ptr u64))))]
        (unsafe
          (ptr-read (int->ptr address : (Ptr ,value-ty)))))
      `(let
        [payload : (Ptr ,value-ty)
          (unsafe
            (int->ptr
              (ptr-read (ptr-cast (ptr-addr-of ,value) : (Ptr u64)))
              : (Ptr ,value-ty)))]
        (unsafe
          (__tl-project-field
            (deref payload)
            ,(comptime.expr-list-nth fields 0)))))))

;; A non-Box is already the payload: matching a Box through a shared reference
;; binds (& T). An optional selector reads just one field, preserving the
;; payload's other owners; without it the existing whole-payload view is used.
(defmacro (compiler-owned-box-shared-view [value : Expr] [fields : Expr ...]) : Expr
  (let
    [count : i64 (comptime.expr-list-length fields)]
    [value-ty : comptime.Expr (comptime.expr-type value)]
    (if (> count 1)
      (comptime.error "box view accepts at most one field selector")
      unit)
    (if (string-eq (type-kind value-ty) "box")
      `(compiler-owned-typed-box-shared-view
        ,value
        ,(comptime.box-element-type value-ty)
        ,@fields)
      (if (= count 0)
        value
        `(let
          [payload ,value]
          (compiler-owned-reference-shared-view
            (& (__tl-project-field payload ,(comptime.expr-list-nth fields 0)))))))))