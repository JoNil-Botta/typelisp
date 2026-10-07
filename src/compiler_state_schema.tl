;; compiler_state_schema.tl - Declarative schemas for packed compiler state
;; (#7021).
;;
;; Hot compiler modules keep mutable state behind a one-word owner handle
;; instead of copying a wide aggregate. A schema names each private field once,
;; with its type and initializer, and generates the only code that addresses
;; the storage, so a call site can no longer pair a slot with the wrong type.
(import stdlib.comptime)

;; `compiler-state-directory-schema` declares the private fields of a state
;; handle, one `[name : Type init]` clause each, and generates the whole access
;; surface from that one list (#7021):
;; - `PREFIX-NAME` and `PREFIX-set-NAME!`, a typed reader and writer per field,
;;   and `PREFIX-NAME-slot`, the field's directory index, which only they read;
;; - `PREFIX-slot-count`, and `PREFIX-from-seed`, which allocates the directory
;;   and one cell per field in clause order;
;; - `PREFIX-fingerprints`, one fingerprint per observed field in clause order,
;;   for state-isolation tests.
;;
;; The state type is a one-word struct `(address i64)` naming the directory, an
;; array of cell addresses. Every field keeps its own stable typed cell, so an
;; access reads one directory word and then the cell: no lookup, branch,
;; allocation or wide copy. Nothing else may address the cells; the generated
;; readers and writers are the only raw accesses.
;;
;; The SEED and ADDRESS operands name the bindings an initializer may read: the
;; `seed-type` value passed to `PREFIX-from-seed`, and the new directory's
;; address. An initializer may be wrapped in:
;; - `(unobserved INIT)`: the field is left out of `PREFIX-fingerprints`;
;; - `(observed-by FN INIT)`: the field is fingerprinted as
;;   `(FN (PREFIX-NAME state))` instead of by the words of its cell.
;; Generated code reads `hash.combine` and `hash.i64` in the module it expands
;; into.
(defmacro (compiler-state-directory-schema
  [prefix : Expr]
  [state-type : type]
  [seed-type : type]
  [seed : Expr]
  [address : Expr]
  [fields : ExprBindingClause ...]) : Decls
  (let
    [prefix-text : String
      (match prefix
        [(Expr.Var value) value]
        [_
          (comptime-error
            "compiler-state-directory-schema: prefix must be a bare name")])]
    [state-constructor : Expr
      (comptime.expr-var (type-nominal-name state-type))]
    [slot-count-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-slot-count"))]
    [from-seed-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-from-seed"))]
    [fingerprints-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-fingerprints"))]
    [cell-fingerprint-name : Expr
      (comptime.expr-var
        (comptime.string-append prefix-text "-cell-fingerprint"))]
    [seed-text : String
      (match seed
        [(Expr.Var value) value]
        [_
          (comptime-error
            "compiler-state-directory-schema: the seed binding must be a bare name")])]
    [address-text : String
      (match address
        [(Expr.Var value) value]
        [_
          (comptime-error
            "compiler-state-directory-schema: the address binding must be a bare name")])]
    [count : i64 (comptime.expr-binding-clause-list-length fields)]
    [index : i64 0]
    [accessors : ExprList (comptime.expr-list-empty)]
    [inits : ExprList (comptime.expr-list-empty)]
    [prints : ExprList (comptime.expr-list-empty)]
    [observed : i64 0]
    (while (< index count)
      (let
        [clause : ExprBindingClause
          (comptime.expr-binding-clause-list-nth fields index)]
        [name : String (comptime.expr-binding-clause-name clause)]
        [ty : Expr
          (if (comptime.expr-binding-clause-has-type? clause)
            (comptime.expr-binding-clause-type clause)
            (comptime-error
              "compiler-state-directory-schema: every field needs a type, `[name : Type init]`"))]
        [init1 : Expr (comptime.expr-binding-clause-init clause)]
        [wrapper : String
          (match init1
            [(Expr.Call callee _)
              (match callee
                [(Expr.Var value) value]
                [_ ""])]
            [_ ""])]
        [policy : String
          (match wrapper
            ["unobserved" "unobserved"]
            ["observed-by" "observed-by"]
            [_ "cell"])]
        [init : Expr
          (match policy
            ["unobserved"
              (match init1
                [(Expr.Call _ items) (comptime.expr-list-nth items 0)]
                [_ init1])]
            ["observed-by"
              (match init1
                [(Expr.Call _ items) (comptime.expr-list-nth items 1)]
                [_ init1])]
            [_ init1])]
        [slot : Expr (comptime.expr-int index)]
        ;; The accessors read the slot from a global, as a `gep` operand; a
        ;; literal operand costs the optimizer's single-block inliner one
        ;; more counted instruction, which keeps a reader wrapped in one more
        ;; function from inlining.
        [slot-global : Expr
          (comptime.expr-var
            (comptime.string-append
              prefix-text
              (comptime.string-append "-" (comptime.string-append name "-slot"))))]
        [getter : Expr
          (comptime.expr-var
            (comptime.string-append
              prefix-text
              (comptime.string-append "-" name)))]
        [setter : Expr
          (comptime.expr-var
            (comptime.string-append
              prefix-text
              (comptime.string-append "-set-" (comptime.string-append name "!"))))]
        [cell-address : Expr
          `(unsafe
            (ptr-read
              (ptr-offset
                (int->ptr (cast state.address : u64) : (Ptr i64))
                ,slot-global)))]
        [reader : Expr
          `(define (,getter [state : ,state-type]) : ,ty
            (unsafe
              (ptr-read (int->ptr (cast ,cell-address : u64) : (Ptr ,ty)))))]
        [writer : Expr
          `(define (,setter [state : ,state-type] [value : ,ty]) : unit
            (unsafe
              (ptr-write!
                (int->ptr (cast ,cell-address : u64) : (MutPtr ,ty))
                value)))]
        [fill : Expr
          `(set!
            (array-ref cells ,slot)
            (let
              [cell : (__tl_dyn-array ,ty) (__tl_make-array ,ty 1)]
              (set! (array-ref cell 0) ,init)
              (cast
                (unsafe
                  (ptr->int (ptr-cast (__tl_array-data cell) : (Ptr ,ty))))
                : i64)))]
        (set!
          accessors
          (comptime.expr-list-cons
            `(define ,slot-global : i64
              ,slot)
            accessors))
        (set! accessors (comptime.expr-list-cons reader accessors))
        (set! accessors (comptime.expr-list-cons writer accessors))
        (set! inits (comptime.expr-list-cons fill inits))
        (match policy
          ["unobserved" unit]
          ["observed-by"
            (let
              [print-fn : Expr
                (match init1
                  [(Expr.Call _ items) (comptime.expr-list-nth items 0)]
                  [_ init1])]
              (set!
                prints
                (comptime.expr-list-cons
                  `(set!
                    (array-ref out ,(comptime.expr-int observed))
                    (,print-fn (,getter state)))
                  prints))
              (set! observed (+ observed 1)))]
          [_
            (set!
              prints
              (comptime.expr-list-cons
                `(set!
                  (array-ref out ,(comptime.expr-int observed))
                  (,cell-fingerprint-name
                    state
                    ,slot
                    (comptime (/ (+ (size-of (type ,ty)) 7) 8))))
                prints))
            (set! observed (+ observed 1))]))
      (set! index (+ index 1)))
    `(begin
      (define ,slot-count-name : i64
        ,(comptime.expr-int count))
      ;; The initializers see the caller's names for the seed and the
      ;; directory address, bound by name rather than hygienically.
      (define (,from-seed-name [seed-value : ,seed-type]) : ,state-type
        (let
          [cells : (__tl_dyn-array i64) (__tl_make-array i64 ,slot-count-name)]
          [directory : i64
            (cast
              (unsafe
                (ptr->int (ptr-cast (__tl_array-data cells) : (Ptr i64))))
              : i64)]
          ,(comptime.expr-let-scope
            seed-text
            `seed-value
            (comptime.expr-let-scope
              address-text
              `directory
              `(begin
                ,@inits
                (,state-constructor directory))))))
      ;; The words of one cell, hashed in order.
      (define (,cell-fingerprint-name
        [state : ,state-type]
        [slot : i64]
        [word-count : i64]) : i64
        (let
          [base : i64
            (unsafe
              (ptr-read
                (ptr-offset
                  (int->ptr (cast state.address : u64) : (Ptr i64))
                  slot)))]
          [index : i64 0]
          [out : i64 0]
          (while (< index word-count)
            (set!
              out
              (hash.combine
                out
                (hash.i64
                  (unsafe
                    (ptr-read
                      (int->ptr (cast (+ base (* index 8)) : u64) : (Ptr i64)))))))
            (set! index (+ index 1)))
          out))
      (define (,fingerprints-name [state : ,state-type]) : (__tl_dyn-array i64)
        (let
          [out : (__tl_dyn-array i64)
            (__tl_make-array i64 ,(comptime.expr-int observed))]
          ,@prints
          out))
      ,@accessors)))