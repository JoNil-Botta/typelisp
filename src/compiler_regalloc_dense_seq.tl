;; compiler_regalloc_dense_seq.tl - Declaration generation for regalloc's
;; append-only dense sequences.
;;
;; `(compiler-reg-dense-seq T Seq empty-name push-name)` declares, for a struct
;; `Seq` whose fields are exactly `(slots (__tl_dyn-array T))` then `(len i64)`:
;;   empty-name  a zero-length sequence over a zero-capacity backing array
;;   push-name   append one `T`, growing through compiler-reg-seq-grown-capacity
;; The declarations are ordinary concrete functions: no runtime type dispatch
;; and no allocation beyond the growth copy.
;;
;; The live logical sequence is the `slots[0 .. len)` prefix. `push` with spare
;; capacity writes `slots[len]` in the backing array it was given, so a value
;; retained from before the push still reads its own unchanged prefix, but two
;; pushes onto one retained value write the same slot: the sequences are not
;; persistent. Growth copies the live prefix into fresh storage.
(import stdlib.comptime)

;; Capacity for a sequence that must hold one more element than its full
;; backing array: 4 from any capacity below 4, then doubling.
(define (compiler-reg-seq-grown-capacity [cap : i64]) : i64
  (if (< cap 4)
    4
    (* cap 2)))

(defmacro (compiler-reg-dense-seq
  [T : type (:kind i64 struct enum)]
  [seq-type : type (:kind struct)]
  [empty-name : Expr]
  [push-name : Expr]) : Decls
  (let
    [empty-expr : Expr
      (match empty-name
        [(Expr.Var value) (comptime.expr-var value)]
        [_
          (comptime-error
            "compiler-reg-dense-seq: empty declaration must be a bare name")])]
    [push-expr : Expr
      (match push-name
        [(Expr.Var value) (comptime.expr-var value)]
        [_
          (comptime-error
            "compiler-reg-dense-seq: push declaration must be a bare name")])]
    [layout? : bool
      (if (= (struct-field-count seq-type) 2)
        (if (string-eq (struct-field-name seq-type 0) "slots")
          (if (string-eq (type-kind (struct-field-type seq-type 0)) "dyn-array")
            (if (string-eq
              (type-key (array-element-type (struct-field-type seq-type 0)))
              (type-key T))
              (if (string-eq (struct-field-name seq-type 1) "len")
                (string-eq (type-kind (struct-field-type seq-type 1)) "i64")
                false)
              false)
            false)
          false)
        false)]
    [seq : Expr
      (if layout?
        (comptime.expr-var (type-nominal-name seq-type))
        (comptime-error
          "compiler-reg-dense-seq: sequence type must have exactly the fields `(slots (__tl_dyn-array T))` and `(len i64)`"))]
    `(begin
      (define (,empty-expr) : ,seq-type
        (,seq (__tl_make-array ,T 0) 0))
      (define (,push-expr [items : ,seq-type] [item : ,T]) : ,seq-type
        (let
          [slots : (__tl_dyn-array ,T) items.slots]
          [len : i64 items.len]
          (begin
            (if (< len (array-length slots))
              unit
              (let
                [bigger : (__tl_dyn-array ,T)
                  (__tl_make-array
                    ,T
                    (compiler-reg-seq-grown-capacity (array-length slots)))]
                [index : i64 0]
                (begin
                  (while (< index len)
                    (begin
                      (set! (array-ref bigger index) (array-ref slots index))
                      (set! index (+ index 1))))
                  (set! slots bigger))))
            (set! (array-ref slots len) item)
            (,seq slots (+ len 1))))))))