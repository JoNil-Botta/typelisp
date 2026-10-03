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
;; facts)` for the shared mechanics below. Family-specific lookups stay beside
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
(import stdlib.comptime)
(import compiler_owned_view)

;: Emit the shared operations of a concrete scoped-stack family `stack-type`
;: of `T` entries, named `<prefix>-empty`, `-with-capacity`, `-len`, `-empty?`,
;: `-last`, `-last-ref`, `-prefix`, `-push`, `-mark`, `-truncate` and `-release`. `stack-type` must be
;: a struct of `slots` (`(__tl_dyn-array T)`), `len` (i64) and `top`
;: (`(__tl_dyn-array i64)`), in that order.
(defmacro (compiler-scoped-stack-operations
  [T
    : type
    (:kind i64 i32 i16 i8 u64 u32 u16 u8 f64 f32 bool char string unit array dyn-array box function tuple struct enum str ptr mut-ptr ref mut-ref)]
  [stack-type : type]
  [prefix : Expr]) : Decls
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
    [ctor : Expr (comptime.expr-var (type-nominal-name stack-type))]
    `(begin
      ;; Every empty snapshot shares one zero-capacity lineage: no push can
      ;; land in it in place, so its `top` is never read.
      (define ,empty-slots : (__tl_dyn-array ,T)
        (__tl_make-array ,T 0))
      (define ,empty-top : (__tl_dyn-array i64)
        (__tl_make-array i64 1))
      (define (,empty-name) : ,stack-type
        (,ctor
          (unsafe
            (ptr-read (ptr-addr-of ,empty-slots)))
          0
          (unsafe
            (ptr-read (ptr-addr-of ,empty-top)))))
      ;; A fresh lineage with room for `capacity` entries.
      (define (,with-capacity-name [capacity : i64]) : ,stack-type
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
      (define (,len-name [s : (& s ,stack-type)]) : i64
        s.len)
      (define (,emptiness-name [s : (& s ,stack-type)]) : bool
        (= s.len 0))
      ;; The newest entry, a shallow read. The caller checks `len` first.
      (define (,last-name [s : (& s ,stack-type)]) : ,T
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data s.slots) (- s.len 1)))))
      ;; The newest entry, borrowed. The caller checks `len` first.
      (define (,last-ref-name [s : (& s ,stack-type)]) : (& s ,T)
        (& (array-ref s.slots (- s.len 1))))
      ;; The first `count` entries: the snapshot as it was `len - count`
      ;; pushes ago, sharing its lineage.
      (define (,prefix-name [s : (& s ,stack-type)] [count : i64]) : ,stack-type
        (,ctor
          (compiler_owned_view.compiler-owned-reference-shared-view (& s.slots))
          (if (< count 0)
            0
            (if (> count s.len)
              s.len
              count))
          (compiler_owned_view.compiler-owned-reference-shared-view (& s.top))))
      (define (,copy-name
        [dst : (&mut dst (__tl_dyn-array ,T))]
        [src : (& src (__tl_dyn-array ,T))]
        [count : i64]) : unit
        (let
          [index : i64 0]
          (while (< index count)
            (begin
              (set! (array-ref dst index) (array-ref src index))
              (set! index (+ index 1))))))
      ;; `s` with `value` on top. In place when `s` is its lineage's top and
      ;; has room; otherwise into a fresh lineage holding a copy of `s`.
      (define (,push-name [s : ,stack-type] [value : ,T]) : ,stack-type
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
      (define (,push-copy-name
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
      (define (,mark-name [s : (& s ,stack-type)]) : i64
        s.len)
      ;; `s` cut back to `mark`, with every longer snapshot of its lineage
      ;; declared dead: the next push onto the result reuses their slots.
      (define (,truncate-name [s : ,stack-type] [mark : i64]) : ,stack-type
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
      ;; `s` is dead: when nothing beyond it is in use, its lineage goes back to
      ;; `mark` (a length no greater than the snapshot `s` was pushed onto), so
      ;; a scope that pushed onto a snapshot for a moment hands the slots back.
      ;; A copied `s`, or one that later pushes outgrew, changes nothing.
      (define (,release-name [s : (& s ,stack-type)] [mark : i64]) : unit
        (if (and
          (> (array-length s.slots) 0)
          (= (array-ref s.top 0) s.len)
          (>= mark 0)
          (<= mark s.len))
          (set! (array-ref s.top 0) mark)
          unit)))))