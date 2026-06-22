;# Lifetime-scoped slice views for generated `stdlib/vector.tl` modules.
;#
;# `(slice T)` emits a module with `Slice`, `Source`, iterator state, and
;# helpers over the matching `(vector T)` module's `Vec`. A slice is a non-owning
;# view over a vector live prefix or an explicit `(Array T)` live prefix. It keeps
;# a borrowed source witness plus a borrowed backing-array reference, so the
;# checker ties the view to the source owner lifetime.
(module stdlib.vector_slice)

(import stdlib.vector)

;: Emit a generated borrowed slice module for element type `T`.
(defmacro (slice [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "stdlib.vector_slice.generated." (type-key T)))]
    `(begin
      (module ,module-name)
      (import stdlib.vector)
      (import (vector.vector ,T) as vec)
      (defenum Source
        (:lifetimes source)
        (FromVec (& source vec.Vec))
        (FromArray (& source (Array ,T))))
      (defstruct Slice
        (:lifetimes source)
        (witness (Source source))
        (slots (& source (Array ,T)))
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
      (define (live-count-valid? [items : (& source (Array ,T))] [count : i64]) : bool
        (if (< count 0)
          false
          (<= count (array-length items))))
      (define (all-vec [v : (& source vec.Vec)]) : (Slice source)
        (Slice (Source.FromVec v) (vec.slots v) 0 (vec.len v)))
      (define (from-vec [v : (& source vec.Vec)] [start : i64] [len : i64]) : (Slice
          source)
        (if (range-valid? (vec.len v) start len)
          (Slice (Source.FromVec v) (vec.slots v) start len)
          (Slice (Source.FromVec v) (vec.slots v) 0 0)))
      (define (from-array
        [items : (& source (Array ,T))]
        [count : i64]
        [start : i64]
        [len : i64]) : (Slice source)
        (if (live-count-valid? items count)
          (if (range-valid? count start len)
            (Slice (Source.FromArray items) items start len)
            (Slice (Source.FromArray items) items 0 0))
          (Slice (Source.FromArray items) items 0 0)))
      (define (len [slice : (Slice source)]) : i64
        (struct-get slice len))
      (define (is-empty? [slice : (Slice source)]) : bool
        (<= (len slice) 0))
      (define (get [slice : (Slice source)] [index : i64] [fallback : ,T]) : ,T
        (if (if (>= index 0)
          (< index (len slice))
          false)
          (array-ref
            (struct-get slice slots)
            (+ (struct-get slice start) index))
          fallback))
      (defstruct Iter
        (:lifetimes source)
        (slots (& source (Array ,T)))
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
      (define (next [iter : (Iter source)]) : (IterNext source)
        (let
          [index : i64 (struct-get iter index)]
          (if (>= index (struct-get iter len))
            (IterNext.Done iter)
            (let
              [value : ,T
                (array-ref
                  (struct-get iter slots)
                  (+ (struct-get iter start) index))]
              (IterNext.Item
                value
                (Iter
                  (struct-get iter slots)
                  (struct-get iter start)
                  (struct-get iter len)
                  (+ index 1)))))))
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
            (struct-get slice witness)
            (struct-get slice slots)
            (+ (struct-get slice start) start)
            count)
          (Slice
            (struct-get slice witness)
            (struct-get slice slots)
            (struct-get slice start)
            0)))
      (define (to-array [slice : (Slice source)]) : (Array ,T)
        (let
          [n : i64 (len slice)]
          [out : (Array ,T) (make-array ,T n)]
          [i : i64 0]
          (begin
            (while (< i n)
              (begin
                (array-set!
                  out
                  i
                  (array-ref
                    (struct-get slice slots)
                    (+ (struct-get slice start) i)))
                (set! i (+ i 1))))
            out)))
      (define (to-vec [slice : (Slice source)]) : vec.Vec
        (let
          [items : (Array ,T) (to-array slice)]
          (vec.from-array (& items) (len slice))))
      (export
        (type Source)
        (variant FromVec)
        (variant FromArray)
        (type Slice)
        (constructor Slice)
        (type Iter)
        (constructor Iter)
        (type IterNext)
        (variant Done)
        (variant Item)
        (value range-valid?)
        (value live-count-valid?)
        (value all-vec)
        (value from-vec)
        (value from-array)
        (value len)
        (value is-empty?)
        (value get)
        (value iterator)
        (value next)
        (value iter-done?)
        (value iter-value-or)
        (value iter-state)
        (value sub-slice)
        (value to-array)
        (value to-vec)))))

(export (macro slice))

(cfg test (import stdlib.test))
(cfg test (import (stdlib.vector.vector i64) as i64v))
(cfg test (import (stdlib.vector_slice.slice i64) as i64s))
(cfg test (import (stdlib.vector_slice.slice i64) as i64s_again))

(cfg
  test
  (define (vector-slice-test-main) : unit
    (let
      [src : (Array i64) (make-array i64 3)]
      (begin
        (array-set! src 0 5)
        (array-set! src 1 6)
        (array-set! src 2 7)
        (let
          [fv : i64v.Vec (i64v.from-array (& src) 3)]
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
                  "sub-slice overrun -> empty")))
            (let
              [from-array : (i64s.Slice src) (i64s.from-array (& src) 3 0 2)]
              [bad-count : (i64s.Slice src) (i64s.from-array (& src) 4 0 1)]
              [bad-array-range : (i64s.Slice src)
                (i64s.from-array (& src) 3 1 3)]
              (begin
                (test.assert-i64-eq
                  (i64s.get from-array 1 -1)
                  6
                  "slice from array reads live prefix")
                (test.assert-true
                  (i64s.is-empty? bad-count)
                  "slice live count past array length -> empty")
                (test.assert-true
                  (i64s.is-empty? bad-array-range)
                  "slice array range past live count -> empty")))
            (let
              [slice-copy : (Array i64) (i64s.to-array middle)]
              [slice-vec : i64v.Vec (i64s.to-vec middle)]
              (begin
                (test.assert-i64-eq
                  (array-length slice-copy)
                  2
                  "slice copy array length")
                (test.assert-i64-eq
                  (array-ref slice-copy 0)
                  6
                  "slice copy array first")
                (array-set! slice-copy 0 0)
                (test.assert-i64-eq
                  (i64s.get middle 0 -1)
                  6
                  "slice copy independent")
                (test.assert-i64-eq
                  (i64v.len (& slice-vec))
                  2
                  "slice to vec len")
                (test.assert-i64-eq
                  (i64v.get (& slice-vec) 1 -1)
                  7
                  "slice to vec second")))
            (let
              [iter0 : (i64s.Iter fv) (i64s.iterator middle)]
              [step1 : (i64s.IterNext fv) (i64s.next iter0)]
              [iter1 : (i64s.Iter fv) (i64s.iter-state step1)]
              [step2 : (i64s.IterNext fv) (i64s.next iter1)]
              [iter2 : (i64s.Iter fv) (i64s.iter-state step2)]
              [step3 : (i64s.IterNext fv) (i64s.next iter2)]
              [iter3 : (i64s.Iter fv) (i64s.iter-state step3)]
              (begin
                (test.assert-i64-eq
                  (i64s.iter-value-or step1 -1)
                  6
                  "slice iterator first")
                (test.assert-i64-eq
                  (i64s.iter-value-or step2 -1)
                  7
                  "slice iterator second")
                (test.assert-true
                  (i64s.iter-done? step3)
                  "slice iterator exhausted")
                (test.assert-true
                  (i64s.iter-done? (i64s.next iter3))
                  "slice iterator repeated exhaustion")))
            (let
              [empty-slice : (i64s.Slice fv) (i64s.from-vec (& fv) 2 2)]
              [empty-iter : (i64s.Iter fv) (i64s.iterator empty-slice)]
              (test.assert-true
                (i64s.iter-done? (i64s.next empty-iter))
                "empty slice iterator exhausted"))))))))

(cfg
  test
  (test
    vector-slice-api
    (begin
      (vector-slice-test-main)
      unit)))