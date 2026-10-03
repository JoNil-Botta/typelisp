;; compiler_scoped_stack.tl - Declaration generation for compiler-private scoped
;; stacks: the dense replacement for a persistent cons list that a pass extends
;; inside a scope and abandons on the way out.
;;
;; A family declares its own concrete struct beside its element type,
;;
;;   (defstruct Facts
;;     (slots (__tl_dyn-array Fact))
;;     (len i64)
;;     (top (__tl_dyn-array i64)))
;;
;; and invokes `(scoped_stack.compiler-scoped-stack-operations Fact Facts
;; facts empty push prefix)` for the selected mechanics below. Family-specific lookups stay beside
;; the invocation.
;;
;; A value of the family is a SNAPSHOT, read like the list it replaces: its
;; entries are `slots[0 .. len)`, newest last. Snapshots that share `slots`
;; form a lineage, and the lineage's `top` cell holds how far its slots are in
;; use. An entry below a live snapshot's `len` is never written again, so every
;; snapshot keeps reading exactly what it held when it was made, however the
;; others grow; that is what lets a pass hand one snapshot to several scopes
;; the way it handed them one list.
;;
;; - `push` appends in place when the snapshot is its lineage's top (the common
;;   case: a scope extends what it was given) and otherwise copies the entries
;;   into a fresh lineage, so extending an older snapshot never disturbs a
;;   newer one.
;; - `mark` is a snapshot's length, and `truncate` returns the snapshot cut
;;   back to a mark AND declares every longer snapshot of its lineage dead, so
;;   the next push reuses those slots instead of copying. Only a caller that
;;   knows the longer snapshots are dead (a scope it has left) may truncate.
;; - `release` is the guarded form for a snapshot pushed for a moment: once it
;;   is dead, its lineage goes back to the mark if nothing beyond it is in use.
;; - `prefix` reads the first entries as a snapshot without touching the
;;   lineage; it is the list's `rest`.
;; - `last` and `last-ref` require a nonempty snapshot. Elements are shallow
;;   arena values; no operation takes ownership or runs element cleanup.
(import stdlib.comptime)
(import compiler_owned_view)

;: Emit only the requested operations of a concrete scoped-stack family.
;: Select bare names: empty, with-capacity, len, empty?, last, last-ref, prefix,
;: push, mark, truncate, release. Push includes its copy/growth helpers; empty
;: includes its immutable zero-capacity globals. `stack-type` must be
;: a struct of `slots` (`(__tl_dyn-array T)`), `len` (i64) and `top`
;: (`(__tl_dyn-array i64)`), in that order.
(defmacro (compiler-scoped-stack-operations
  [T
    : type
    (:kind i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char string unit array dyn-array box function tuple struct enum str ptr mut-ptr ref mut-ref)]
  [stack-type : type]
  [prefix : Expr]
  [operations : Expr ...]) : Decls
  (let
    [prefix-text : String
      (match prefix
        [(Expr.Var value) value]
        [_
          (comptime-error
            "compiler-scoped-stack-operations: prefix must be a bare name")])]
    [empty-slots : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-empty-slots"))]
    [empty-top : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-empty-top"))]
    [empty-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-empty"))]
    [with-capacity-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-with-capacity"))]
    [len-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-len"))]
    [emptiness-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-empty?"))]
    [last-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-last"))]
    [last-ref-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-last-ref"))]
    [prefix-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-prefix"))]
    [copy-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-copy-range"))]
    [push-copy-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-push-copy"))]
    [push-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-push"))]
    [release-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-release"))]
    [mark-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-mark"))]
    [truncate-name : Expr
      (comptime.expr-var (comptime.string-append prefix-text "-truncate"))]
    [operation-mask : i64 0]
    [operation-index : i64 0]
    [decls : ExprList (comptime.expr-list-empty)]
    [ctor : Expr (comptime.expr-var (type-nominal-name stack-type))]
    (while (< operation-index (comptime.expr-list-length operations))
      (let
        [bit : i64
          (match (comptime.expr-list-nth operations operation-index)
            [(Expr.Var operation)
              (match operation
                ["empty" 1]
                ["with-capacity" 2]
                ["len" 4]
                ["empty?" 8]
                ["last" 16]
                ["last-ref" 32]
                ["prefix" 64]
                ["push" 128]
                ["mark" 256]
                ["truncate" 512]
                ["release" 1024]
                [_
                  (comptime-error
                    "compiler-scoped-stack-operations: unknown operation")])]
            [_
              (comptime-error
                "compiler-scoped-stack-operations: operation must be a bare name")])]
        (if (!= (bit-and operation-mask bit) 0)
          (comptime-error
            "compiler-scoped-stack-operations: duplicate operation")
          unit)
        (set! operation-mask (bit-or operation-mask bit))
        (set! operation-index (+ operation-index 1))))
    (if (= operation-mask 0)
      (comptime-error
        "compiler-scoped-stack-operations: expected at least one operation")
      unit)
    (if (!= (bit-and operation-mask 1024) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,release-name [s : (& s ,stack-type)] [mark : i64]) : unit
            (if (and
              (> (array-length s.slots) 0)
              (= (array-ref s.top 0) s.len)
              (>= mark 0)
              (<= mark s.len))
              (set! (array-ref s.top 0) mark)
              unit))
          decls))
      unit)
    (if (!= (bit-and operation-mask 512) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,truncate-name [s : ,stack-type] [mark : i64]) : ,stack-type
            (let
              [n : i64
                (if (< mark 0)
                  0
                  (if (> mark s.len)
                    s.len
                    mark))]
              [slots : (__tl_dyn-array ,T) s.slots]
              [top : (__tl_dyn-array i64) s.top]
              (begin
                (if (> (array-length slots) 0)
                  (set! (array-ref top 0) n)
                  unit)
                (,ctor slots n top))))
          decls))
      unit)
    (if (!= (bit-and operation-mask 256) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,mark-name [s : (& s ,stack-type)]) : i64
            s.len)
          decls))
      unit)
    (if (!= (bit-and operation-mask 128) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,push-copy-name
            [slots : (__tl_dyn-array ,T)]
            [n : i64]
            [value : ,T]) : ,stack-type
            (let
              [fresh : (__tl_dyn-array ,T)
                (__tl_make-array
                  ,T
                  (if (< n 2)
                    4
                    (* 2 n)))]
              [fresh-top : (__tl_dyn-array i64) (__tl_make-array i64 1)]
              (begin
                (,copy-name (&mut fresh) (& slots) n)
                (set! (array-ref fresh n) value)
                (set! (array-ref fresh-top 0) (+ n 1))
                (,ctor fresh (+ n 1) fresh-top))))
          decls))
      unit)
    (if (!= (bit-and operation-mask 128) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,push-name [s : ,stack-type] [value : ,T]) : ,stack-type
            (let
              [n : i64 s.len]
              [slots : (__tl_dyn-array ,T) s.slots]
              [top : (__tl_dyn-array i64) s.top]
              (if (and (< n (array-length slots)) (= (array-ref top 0) n))
                (begin
                  (set! (array-ref slots n) value)
                  (set! (array-ref top 0) (+ n 1))
                  (,ctor slots (+ n 1) top))
                (,push-copy-name slots n value))))
          decls))
      unit)
    (if (!= (bit-and operation-mask 128) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,copy-name
            [dst : (&mut dst (__tl_dyn-array ,T))]
            [src : (& src (__tl_dyn-array ,T))]
            [count : i64]) : unit
            (let
              [index : i64 0]
              (while (< index count)
                (begin
                  (set! (array-ref dst index) (array-ref src index))
                  (set! index (+ index 1))))))
          decls))
      unit)
    (if (!= (bit-and operation-mask 64) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,prefix-name [s : (& s ,stack-type)] [count : i64]) : ,stack-type
            (,ctor
              (compiler_owned_view.compiler-owned-reference-shared-view
                (& s.slots))
              (if (< count 0)
                0
                (if (> count s.len)
                  s.len
                  count))
              (compiler_owned_view.compiler-owned-reference-shared-view
                (& s.top))))
          decls))
      unit)
    (if (!= (bit-and operation-mask 32) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,last-ref-name [s : (& s ,stack-type)]) : (& s ,T)
            (& (array-ref s.slots (- s.len 1))))
          decls))
      unit)
    (if (!= (bit-and operation-mask 16) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,last-name [s : (& s ,stack-type)]) : ,T
            (unsafe
              (ptr-read (ptr-offset (__tl_array-data s.slots) (- s.len 1)))))
          decls))
      unit)
    (if (!= (bit-and operation-mask 8) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,emptiness-name [s : (& s ,stack-type)]) : bool
            (= s.len 0))
          decls))
      unit)
    (if (!= (bit-and operation-mask 4) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,len-name [s : (& s ,stack-type)]) : i64
            s.len)
          decls))
      unit)
    (if (!= (bit-and operation-mask 2) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,with-capacity-name [capacity : i64]) : ,stack-type
            (let
              [top : (__tl_dyn-array i64) (__tl_make-array i64 1)]
              (begin
                (set! (array-ref top 0) 0)
                (,ctor
                  (__tl_make-array
                    ,T
                    (if (< capacity 1)
                      1
                      capacity))
                  0
                  top))))
          decls))
      unit)
    ;; Every empty snapshot shares a zero-capacity lineage; push never reads its top.
    (if (!= (bit-and operation-mask 1) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define (,empty-name) : ,stack-type
            (,ctor
              (unsafe
                (ptr-read (ptr-addr-of ,empty-slots)))
              0
              (unsafe
                (ptr-read (ptr-addr-of ,empty-top)))))
          decls))
      unit)
    (if (!= (bit-and operation-mask 1) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define ,empty-top : (__tl_dyn-array i64)
            (__tl_make-array i64 1))
          decls))
      unit)
    (if (!= (bit-and operation-mask 1) 0)
      (set!
        decls
        (comptime.expr-list-cons
          `(define ,empty-slots : (__tl_dyn-array ,T)
            (__tl_make-array ,T 0))
          decls))
      unit)
    `(begin
      ,@decls)))