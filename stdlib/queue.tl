;# Generated deque family (collections v1, #1549/#2797).
;#
;# `(deque T)` emits a growable, owned double-ended queue module for element
;# type `T`, backed by a circular `(Array T)`. Queue-style callers use
;# `push-back` with `pop-front`; double-ended callers may also use `push-front`
;# and `pop-back`.
;#
;# Mutating operations take `&mut` and update the deque in place. Growth
;# allocates a larger backing array, copies the live logical range starting at
;# index 0, and resets `head` to 0. Empty pops return `Pop.Empty`; successful
;# pops return `Pop.Ok` with only the removed value. Peeks and indexed reads use
;# caller-supplied fallbacks.
;#
;# Usage:
;#
;# ```typelisp
;# (import "stdlib/queue.tl")
;# (import (deque i64) as deque_i64)
;#
;# (define (main) : i64
;#   (let
;#     [q : deque_i64.Deque (deque_i64.new)]
;#     (begin
;#       (deque_i64.push-back (&mut q) 10)
;#       (deque_i64.push-back (&mut q) 32)
;#       (deque_i64.peek-front (& q) 0))))
;# ```
;: Emit a generated growable deque module for element type `T`.
(defmacro (deque [T : type]) : Module
  (let
    [module-name : Expr
      (expr-var (string-append "stdlib.queue.deque.generated." (type-key T)))]
    [deque-name : Expr (expr-var "Deque")]
    [pop-name : Expr (expr-var "Pop")]
    [pop-empty-name : Expr (expr-var "Pop.Empty")]
    [pop-ok-name : Expr (expr-var "Pop.Ok")]
    `(begin
      (module ,module-name)
      (defstruct ,deque-name
        (slots (Array ,T))
        (head i64)
        (len i64))
      (defenum ,pop-name
        (Empty)
        (Ok ,T))
      (define (slots [q : (& q ,deque-name)]) : (& q (Array ,T))
        (& (struct-get q slots)))
      (define (slots-mut [q : (&mut q ,deque-name)]) : (&mut q (Array ,T))
        (&mut (struct-get q slots)))
      (define (head [q : (& q ,deque-name)]) : i64
        (struct-get q head))
      (define (len [q : (& q ,deque-name)]) : i64
        (struct-get q len))
      (define (len-mut [q : (&mut q ,deque-name)]) : i64
        (struct-get q len))
      (define (capacity [q : (& q ,deque-name)]) : i64
        (array-length (slots q)))
      (define (is-empty? [q : (& q ,deque-name)]) : bool
        (<= (len q) 0))
      (define (with-capacity [capacity : i64]) : ,deque-name
        (let
          [cap : i64
            (if (< capacity 1)
              1
              capacity)]
          (,deque-name (make-array ,T cap) 0 0)))
      (define (new) : ,deque-name
        (with-capacity 4))
      (define (next-index [index : i64] [capacity : i64]) : i64
        (% (+ index 1) capacity))
      (define (prev-index [index : i64] [capacity : i64]) : i64
        (if (<= index 0)
          (- capacity 1)
          (- index 1)))
      (define (physical-index-from [head : i64] [capacity : i64] [offset : i64]) : i64
        (% (+ head offset) capacity))
      (define (physical-index [q : (& q ,deque-name)] [offset : i64]) : i64
        (physical-index-from (head q) (capacity q) offset))
      (define (get [q : (& q ,deque-name)] [index : i64] [fallback : ,T]) : ,T
        (if (if (>= index 0)
          (< index (len q))
          false)
          (array-ref (slots q) (physical-index q index))
          fallback))
      (define (peek-front [q : (& q ,deque-name)] [fallback : ,T]) : ,T
        (get q 0 fallback))
      (define (peek-back [q : (& q ,deque-name)] [fallback : ,T]) : ,T
        (get q (- (len q) 1) fallback))
      (define (copy-live!
        [dst : (&mut dst (Array ,T))]
        [src : (& src (Array ,T))]
        [head : i64]
        [capacity : i64]
        [count : i64]
        [index : i64]) : unit
        (if (>= index count)
          unit
          (begin
            (array-set!
              dst
              index
              (array-ref src (physical-index-from head capacity index)))
            (copy-live! dst src head capacity count (+ index 1)))))
      (define (grow [q : (&mut q ,deque-name)]) : unit
        (let
          [n : i64 (struct-get q len)]
          [old-cap : i64 (array-length (struct-get q slots))]
          [new-cap : i64
            (if (< old-cap 1)
              1
              (* old-cap 2))]
          [bigger : (Array ,T) (make-array ,T new-cap)]
          (begin
            (copy-live!
              (&mut bigger)
              (& (struct-get q slots))
              (struct-get q head)
              old-cap
              n
              0)
            (set! (struct-get q slots) bigger)
            (set! (struct-get q head) 0))))
      (define (push-back [q : (&mut q ,deque-name)] [value : ,T]) : unit
        (begin
          (if (< (struct-get q len) (array-length (struct-get q slots)))
            unit
            (grow q))
          (let
            [old-len : i64 (struct-get q len)]
            [tail : i64
              (physical-index-from
                (struct-get q head)
                (array-length (struct-get q slots))
                old-len)]
            (begin
              (array-set! (struct-get q slots) tail value)
              (set! (struct-get q len) (+ old-len 1))))))
      (define (push-front [q : (&mut q ,deque-name)] [value : ,T]) : unit
        (begin
          (if (< (struct-get q len) (array-length (struct-get q slots)))
            unit
            (grow q))
          (let
            [new-head : i64
              (prev-index
                (struct-get q head)
                (array-length (struct-get q slots)))]
            (begin
              (array-set! (struct-get q slots) new-head value)
              (set! (struct-get q head) new-head)
              (set! (struct-get q len) (+ (struct-get q len) 1))))))
      (define (pop-front [q : (&mut q ,deque-name)]) : ,pop-name
        (if (<= (struct-get q len) 0)
          (,pop-empty-name)
          (let
            [value : ,T
              (clone (array-ref (struct-get q slots) (struct-get q head)))]
            [new-len : i64 (- (struct-get q len) 1)]
            [new-head : i64
              (if (= new-len 0)
                0
                (next-index
                  (struct-get q head)
                  (array-length (struct-get q slots))))]
            (begin
              (set! (struct-get q head) new-head)
              (set! (struct-get q len) new-len)
              (,pop-ok-name value)))))
      (define (pop-back [q : (&mut q ,deque-name)]) : ,pop-name
        (if (<= (struct-get q len) 0)
          (,pop-empty-name)
          (let
            [last-index : i64
              (physical-index-from
                (struct-get q head)
                (array-length (struct-get q slots))
                (- (struct-get q len) 1))]
            [value : ,T (clone (array-ref (struct-get q slots) last-index))]
            [new-len : i64 (- (struct-get q len) 1)]
            [new-head : i64
              (if (= new-len 0)
                0
                (struct-get q head))]
            (begin
              (set! (struct-get q head) new-head)
              (set! (struct-get q len) new-len)
              (,pop-ok-name value)))))
      (export
        (type ,deque-name)
        (constructor ,deque-name)
        (type ,pop-name)
        (variant Empty)
        (variant Ok)
        (value with-capacity)
        (value new)
        (value is-empty?)
        (value len)
        (value capacity)
        (value get)
        (value peek-front)
        (value peek-back)
        (value push-back)
        (value push-front)
        (value pop-front)
        (value pop-back)))))

(export (macro deque))

(cfg test (import "test.tl"))
(cfg test (import (deque i64) as deque_i64))
(cfg test (import (deque i64) as deque_i64_again))

(cfg
  test
  (define (deque-test-len-through-duplicate-import
    [q : (& q deque_i64_again.Deque)]) : i64
    (deque_i64_again.len q)))

(cfg
  test
  (define (deque-test-push-through-duplicate-import
    [q : (&mut q deque_i64_again.Deque)]
    [value : i64]) : unit
    (deque_i64_again.push-back q value)))

(cfg
  test
  (test
    deque-macro-i64-api
    (begin
      (let
        [empty : deque_i64.Deque (deque_i64.with-capacity 2)]
        (begin
          (assert-i64-eq (deque_i64.len (& empty)) 0 "empty len")
          (assert-i64-eq (deque_i64.capacity (& empty)) 2 "empty capacity")
          (assert-true (deque_i64.is-empty? (& empty)) "empty predicate")
          (assert-i64-eq
            (deque_i64.peek-front (& empty) -1)
            -1
            "empty front fallback")
          (assert-i64-eq
            (deque_i64.peek-back (& empty) -1)
            -1
            "empty back fallback")
          (assert-i64-eq (deque_i64.get (& empty) 0 -1) -1 "empty get fallback")
          (let
            [zero-cap : deque_i64.Deque (deque_i64.with-capacity 0)]
            (assert-i64-eq
              (deque_i64.capacity (& zero-cap))
              1
              "zero capacity clamps"))))
      (let
        [q : deque_i64.Deque (deque_i64.with-capacity 3)]
        (begin
          (deque_i64.push-back (&mut q) 10)
          (deque_i64.push-back (&mut q) 20)
          (deque_i64.push-back (&mut q) 30)
          (assert-i64-eq (deque_i64.len (& q)) 3 "three pushes len")
          (assert-i64-eq
            (deque_i64.peek-front (& q) -1)
            10
            "front after pushes")
          (assert-i64-eq (deque_i64.peek-back (& q) -1) 30 "back after pushes")
          (assert-i64-eq (deque_i64.get (& q) 1 -1) 20 "middle read")
          (assert-i64-eq (deque_i64.get (& q) -1 -1) -1 "negative fallback")
          (assert-i64-eq (deque_i64.get (& q) 3 -1) -1 "at-len fallback")
          (match (deque_i64.pop-front (&mut q))
            [(deque_i64.Pop.Ok value)
              (begin
                (assert-i64-eq value 10 "pop-front value")
                (assert-i64-eq
                  (deque_i64.peek-front (& q) -1)
                  20
                  "front advances"))]
            [deque_i64.Pop.Empty (assert-true false "pop-front should succeed")])
          (match (deque_i64.pop-front (&mut q))
            [(deque_i64.Pop.Ok value)
              (assert-i64-eq value 20 "second pop-front value")]
            [deque_i64.Pop.Empty
              (assert-true false "second pop-front should succeed")])))
      (let
        [wrapped : deque_i64.Deque (deque_i64.with-capacity 3)]
        (begin
          (deque_i64.push-back (&mut wrapped) 1)
          (deque_i64.push-back (&mut wrapped) 2)
          (deque_i64.push-back (&mut wrapped) 3)
          (match (deque_i64.pop-front (&mut wrapped))
            [(deque_i64.Pop.Ok value) (assert-i64-eq value 1 "wrap seed pop")]
            [deque_i64.Pop.Empty
              (assert-true false "wrap seed pop should succeed")])
          (deque_i64.push-back (&mut wrapped) 4)
          (deque_i64.push-back (&mut wrapped) 5)
          (assert-i64-eq
            (deque_i64.capacity (& wrapped))
            6
            "wrapped growth capacity")
          (assert-i64-eq (deque_i64.len (& wrapped)) 4 "wrapped growth len")
          (assert-i64-eq (deque_i64.get (& wrapped) 0 -1) 2 "wrapped get 0")
          (assert-i64-eq (deque_i64.get (& wrapped) 1 -1) 3 "wrapped get 1")
          (assert-i64-eq (deque_i64.get (& wrapped) 2 -1) 4 "wrapped get 2")
          (assert-i64-eq (deque_i64.get (& wrapped) 3 -1) 5 "wrapped get 3")
          (assert-i64-eq
            (deque_i64.peek-front (& wrapped) -1)
            2
            "wrapped front")
          (assert-i64-eq (deque_i64.peek-back (& wrapped) -1) 5 "wrapped back")))
      (let
        [dq : deque_i64.Deque (deque_i64.with-capacity 2)]
        (begin
          (deque_i64.push-back (&mut dq) 20)
          (deque_i64.push-front (&mut dq) 10)
          (assert-i64-eq (deque_i64.get (& dq) 0 -1) 10 "push-front get 0")
          (assert-i64-eq (deque_i64.get (& dq) 1 -1) 20 "push-front get 1")
          (match (deque_i64.pop-back (&mut dq))
            [(deque_i64.Pop.Ok back-value)
              (assert-i64-eq back-value 20 "pop-back value")]
            [deque_i64.Pop.Empty (assert-true false "pop-back should succeed")])
          (match (deque_i64.pop-front (&mut dq))
            [(deque_i64.Pop.Ok front-value)
              (assert-i64-eq front-value 10 "final pop-front value")]
            [deque_i64.Pop.Empty
              (assert-true false "final pop-front should succeed")])
          (assert-true (deque_i64.is-empty? (& dq)) "drained deque empty")
          (deque_i64.push-back (&mut dq) 99)
          (assert-i64-eq (deque_i64.len (& dq)) 1 "reuse after drain len")
          (assert-i64-eq
            (deque_i64.peek-front (& dq) -1)
            99
            "reuse after drain value")))
      (let
        [mut : deque_i64.Deque (deque_i64.with-capacity 1)]
        (begin
          (deque_i64.push-back (&mut mut) 1)
          (assert-i64-eq (deque_i64.len (& mut)) 1 "mutable push len")
          (assert-i64-eq (deque_i64.capacity (& mut)) 1 "mutable push capacity")
          (deque_i64.push-front (&mut mut) 0)
          (assert-i64-eq (deque_i64.len (& mut)) 2 "mutable growth len")
          (assert-i64-eq
            (deque_i64.capacity (& mut))
            2
            "mutable growth capacity")
          (assert-i64-eq (deque_i64.get (& mut) 0 -1) 0 "mutable get front")
          (assert-i64-eq (deque_i64.get (& mut) 1 -1) 1 "mutable get back")
          (match (deque_i64.pop-back (&mut mut))
            [(deque_i64.Pop.Ok back-value)
              (assert-i64-eq back-value 1 "mutable pop-back value")]
            [deque_i64.Pop.Empty
              (assert-true false "mutable pop-back should succeed")])
          (assert-i64-eq (deque_i64.len (& mut)) 1 "mutable pop-back len")
          (assert-i64-eq
            (deque_i64.peek-front (& mut) -1)
            0
            "mutable pop-back leaves front")
          (deque_i64.push-back (&mut mut) 2)
          (match (deque_i64.pop-front (&mut mut))
            [(deque_i64.Pop.Ok front-value)
              (assert-i64-eq front-value 0 "mutable pop-front value")]
            [deque_i64.Pop.Empty
              (assert-true false "mutable pop-front should succeed")])
          (assert-i64-eq (deque_i64.len (& mut)) 1 "mutable pop-front len")
          (assert-i64-eq
            (deque_i64.peek-front (& mut) -1)
            2
            "mutable pop-front leaves next")
          (deque-test-push-through-duplicate-import (&mut mut) 7)
          (assert-i64-eq
            (deque-test-len-through-duplicate-import (& mut))
            2
            "duplicate deque import shares type")
          (assert-i64-eq
            (deque_i64_again.peek-back (& mut) -1)
            7
            "duplicate deque import shares operations")))
      (let
        [front-empty : deque_i64.Deque (deque_i64.new)]
        [back-empty : deque_i64.Deque (deque_i64.new)]
        (begin
          (match (deque_i64.pop-front (&mut front-empty))
            [deque_i64.Pop.Empty unit]
            [(deque_i64.Pop.Ok _)
              (assert-true false "empty pop-front should be empty")])
          (match (deque_i64.pop-back (&mut back-empty))
            [deque_i64.Pop.Empty unit]
            [(deque_i64.Pop.Ok _)
              (assert-true false "empty pop-back should be empty")]))))))