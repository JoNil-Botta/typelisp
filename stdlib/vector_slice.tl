;# Lifetime-scoped slice views for generated `stdlib/vector.tl` modules.
;#
;# `(slice T)` emits a module with `Slice`, `MutSlice`, iterator state, and
;# helpers over the matching `(vector T)` module's `Vec`. A slice is a
;# non-owning view over a vector live prefix. Its private backing-buffer
;# reference carries the source owner lifetime.
(import stdlib.comptime)
(import stdlib.vector)

;: Emit a generated borrowed slice module for element type `T`.
(defmacro (slice [T : type]) : Module
  (let
    [module-name : comptime.Expr
      (comptime.expr-var
        (comptime.string-append "stdlib.vector_slice.generated." (type-key T)))]
    [vec-module-name : String
      (comptime.string-append "stdlib.vector.generated." (type-key T))]
    [vec-type-name : comptime.Expr
      (comptime.expr-var (comptime.string-append vec-module-name ".Vec"))]
    `(begin
      (module ,module-name)
      (import (vector.vector ,T) as vec)
      (defstruct Slice
        (:lifetimes source)
        (slots (& source (__tl_dyn-array ,T)))
        (start i64)
        (len i64))
      (defstruct MutSlice
        (:lifetimes source)
        (slots (&mut source (__tl_dyn-array ,T)))
        (start i64)
        (len i64))
      (define (range-valid? [source-len : i64] [start : i64] [len : i64]) : bool
        (let
          [non-negative-range? : bool
            (if (< start 0)
              false
              (if (< len 0)
                false
                true))]
          (if (< source-len 0)
            false
            (if non-negative-range?
              (if (> start source-len)
                false
                (<= len (- source-len start)))
              false))))
      (define (all-vec [v : (& source ,vec-type-name)]) : (Slice source)
        (Slice (vec.slots v) 0 (vec.len v)))
      (define (from-vec
        [v : (& source ,vec-type-name)]
        [start : i64]
        [len : i64]) : (Slice source)
        (if (range-valid? (vec.len v) start len)
          (Slice (vec.slots v) start len)
          (Slice (vec.slots v) 0 0)))
      (define (all-vec-mut [v : (&mut source ,vec-type-name)]) : (MutSlice
          source)
        (MutSlice (vec.slots-mut v) 0 (vec.len-mut v)))
      (define (from-vec-mut
        [v : (&mut source ,vec-type-name)]
        [start : i64]
        [len : i64]) : (MutSlice source)
        (if (range-valid? (vec.len-mut v) start len)
          (MutSlice (vec.slots-mut v) start len)
          (MutSlice (vec.slots-mut v) 0 0)))
      (define (len [slice : (Slice source)]) : i64
        (struct-get slice len))
      (define (mut-len [slice : (MutSlice source)]) : i64
        (struct-get slice len))
      (define (is-empty? [slice : (Slice source)]) : bool
        (<= (len slice) 0))
      (define (mut-is-empty? [slice : (MutSlice source)]) : bool
        (<= (mut-len slice) 0))
      (define (get [slice : (Slice source)] [index : i64] [fallback : ,T]) : ,T
        (if (if (>= index 0)
          (< index (len slice))
          false)
          (array-ref
            (struct-get slice slots)
            (+ (struct-get slice start) index))
          fallback))
      (define (set [slice : (MutSlice source)] [index : i64] [value : ,T]) : unit
        (if (if (>= index 0)
          (< index (mut-len slice))
          false)
          (array-set!
            (struct-get slice slots)
            (+ (struct-get slice start) index)
            value)
          unit))
      (defstruct Iter
        (:lifetimes source)
        (slots (& source (__tl_dyn-array ,T)))
        (start i64)
        (len i64)
        (index i64))
      (defenum IterNext
        (:lifetimes source)
        (Done (Iter source))
        (Item ,T (Iter source)))
      (define (iterator [slice : (Slice source)]) : (Iter source)
        (Iter
          (struct-get slice slots)
          (struct-get slice start)
          (struct-get slice len)
          0))
      (define (next [iter : (&mut iter (Iter source))]) : (IterNext source)
        (let
          [index : i64 (struct-get iter index)]
          (if (>= index (struct-get iter len))
            (IterNext.Done
              (Iter
                (struct-get iter slots)
                (struct-get iter start)
                (struct-get iter len)
                index))
            (let
              [value : ,T
                (array-ref
                  (struct-get iter slots)
                  (+ (struct-get iter start) index))]
              (begin
                (set! (struct-get iter index) (+ index 1))
                (IterNext.Item
                  value
                  (Iter
                    (struct-get iter slots)
                    (struct-get iter start)
                    (struct-get iter len)
                    (+ index 1))))))))
      (define (iter-done? [result : (IterNext source)]) : bool
        (match result
          [(IterNext.Done _) true]
          [(IterNext.Item _ _) false]))
      (define (iter-value-or [result : (IterNext source)] [fallback : ,T]) : ,T
        (match result
          [(IterNext.Item value _) value]
          [(IterNext.Done _) fallback]))
      (define (iter-state [result : (IterNext source)]) : (Iter source)
        (match result
          [(IterNext.Item _ next-state) next-state]
          [(IterNext.Done next-state) next-state]))
      (define (sub-slice [slice : (Slice source)] [start : i64] [count : i64]) : (Slice
          source)
        (if (range-valid? (len slice) start count)
          (Slice
            (struct-get slice slots)
            (+ (struct-get slice start) start)
            count)
          (Slice (struct-get slice slots) (struct-get slice start) 0)))
      (define (to-vec [slice : (Slice source)]) : ,vec-type-name
        (let
          [n : i64 (len slice)]
          [out : ,vec-type-name (vec.with-capacity n)]
          [i : i64 0]
          (begin
            (while (< i n)
              (begin
                (vec.push
                  (&mut out)
                  (array-ref
                    (struct-get slice slots)
                    (+ (struct-get slice start) i)))
                (set! i (+ i 1))))
            out))))))

(cfg test (import stdlib.test))
(cfg test (import (stdlib.vector.vector i64) as i64v))
(cfg test (import (stdlib.vector_slice.slice i64) as i64s))
(cfg test (import (stdlib.vector_slice.slice i64) as i64s_again))

(cfg
  test
  (define (vector-slice-test-source) : i64v.Vec
    (let
      [v : i64v.Vec (i64v.with-capacity 3)]
      (begin
        (i64v.push (&mut v) 5)
        (i64v.push (&mut v) 6)
        (i64v.push (&mut v) 7)
        v))))

(cfg
  test
  (define (vector-slice-test-basic) : unit
    (let
      [fv : i64v.Vec (vector-slice-test-source)]
      [full : (i64s.Slice fv) (i64s.all-vec (& fv))]
      [middle : (i64s.Slice fv) (i64s.from-vec (& fv) 1 2)]
      (begin
        (test.assert-i64-eq (i64s.len full) 3 "full slice len")
        (test.assert-i64-eq (i64s.len middle) 2 "middle slice len")
        (test.assert-i64-eq
          (i64s_again.len middle)
          2
          "duplicate slice import len")
        (test.assert-false (i64s.is-empty? middle) "middle slice not empty")
        (test.assert-i64-eq (i64s.get middle 0 -1) 6 "middle slice first")
        (test.assert-i64-eq (i64s.get middle 1 -1) 7 "middle slice second")
        (test.assert-i64-eq
          (i64s.get middle 2 -1)
          -1
          "middle slice high fallback")
        (test.assert-i64-eq
          (i64s.get middle -1 -1)
          -1
          "middle slice negative fallback")
        (let
          [bad-start : (i64s.Slice fv) (i64s.from-vec (& fv) -1 1)]
          [bad-range : (i64s.Slice fv) (i64s.from-vec (& fv) 2 2)]
          (begin
            (test.assert-true
              (i64s.is-empty? bad-start)
              "slice negative start -> empty")
            (test.assert-true
              (i64s.is-empty? bad-range)
              "slice overrun -> empty")))
        (let
          [tail : (i64s.Slice fv) (i64s.sub-slice middle 1 1)]
          [bad-tail : (i64s.Slice fv) (i64s.sub-slice middle 1 2)]
          (begin
            (test.assert-i64-eq (i64s.get tail 0 -1) 7 "sub-slice value")
            (test.assert-true
              (i64s.is-empty? bad-tail)
              "sub-slice overrun -> empty")))))))

(cfg
  test
  (define (vector-slice-test-vec-copy) : unit
    (let
      [fv : i64v.Vec (vector-slice-test-source)]
      [middle : (i64s.Slice fv) (i64s.from-vec (& fv) 1 2)]
      [slice-vec : i64v.Vec (i64s.to-vec middle)]
      (begin
        (test.assert-i64-eq (i64v.len (& slice-vec)) 2 "slice to vec len")
        (test.assert-i64-eq
          (i64v.get (& slice-vec) 0 -1)
          6
          "slice to vec first")
        (test.assert-i64-eq
          (i64v.get (& slice-vec) 1 -1)
          7
          "slice to vec second")
        (i64v.set (&mut slice-vec) 0 0)
        (test.assert-i64-eq
          (i64s.get middle 0 -1)
          6
          "slice to vec copy is independent")))))

(cfg
  test
  (define (vector-slice-test-iterator) : unit
    (let
      [fv : i64v.Vec (vector-slice-test-source)]
      [middle : (i64s.Slice fv) (i64s.from-vec (& fv) 1 2)]
      (begin
        (let
          [iter : (i64s.Iter fv) (i64s.iterator middle)]
          (begin
            (let
              [step1 : (i64s.IterNext fv) (i64s.next (&mut iter))]
              (test.assert-i64-eq
                (i64s.iter-value-or step1 -1)
                6
                "slice iterator first"))
            (let
              [step2 : (i64s.IterNext fv) (i64s.next (&mut iter))]
              (test.assert-i64-eq
                (i64s.iter-value-or step2 -1)
                7
                "slice iterator second"))
            (let
              [step3 : (i64s.IterNext fv) (i64s.next (&mut iter))]
              (test.assert-true
                (i64s.iter-done? step3)
                "slice iterator exhausted"))
            (test.assert-true
              (i64s.iter-done? (i64s.next (&mut iter)))
              "slice iterator repeated exhaustion")))
        (let
          [empty-slice : (i64s.Slice fv) (i64s.from-vec (& fv) 2 2)]
          [empty-iter : (i64s.Iter fv) (i64s.iterator empty-slice)]
          (test.assert-true
            (i64s.iter-done? (i64s.next (&mut empty-iter)))
            "empty slice iterator exhausted"))))))

(cfg
  test
  (define (vector-slice-test-mut) : unit
    (let
      [dst : i64v.Vec (i64v.with-capacity 3)]
      (begin
        (i64v.push (&mut dst) 0)
        (i64v.push (&mut dst) 0)
        (i64v.push (&mut dst) 0)
        (let
          [full-mut : (i64s.MutSlice dst) (i64s.all-vec-mut (&mut dst))]
          (begin
            (test.assert-i64-eq
              (i64s.mut-len full-mut)
              3
              "full mutable slice len")
            (test.assert-false
              (i64s.mut-is-empty? full-mut)
              "full mutable slice not empty")
            (i64s.set full-mut 1 44)
            (array-set!
              (struct-get full-mut slots)
              (struct-get full-mut start)
              33)))
        (test.assert-i64-eq
          (i64v.get (& dst) 0 -1)
          33
          "mutable slice field write updates vector")
        (test.assert-i64-eq
          (i64v.get (& dst) 1 -1)
          44
          "mutable slice set updates vector")
        (let
          [bad-mut : (i64s.MutSlice dst) (i64s.from-vec-mut (&mut dst) 2 2)]
          (test.assert-true
            (i64s.mut-is-empty? bad-mut)
            "mutable slice overrun -> empty"))))))

(cfg
  test
  (define (vector-slice-test-main) : unit
    (begin
      (vector-slice-test-basic)
      (vector-slice-test-vec-copy)
      (vector-slice-test-iterator)
      (vector-slice-test-mut))))

(cfg
  test
  (test
    vector-slice-api
    (begin
      (vector-slice-test-main)
      unit)))