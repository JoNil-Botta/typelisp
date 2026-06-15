;# Dynamic `i64` queue/deque (collections v1, #1549).
;#
;# A growable, owned double-ended queue of `i64` values backed by a circular
;# `(Array i64)`. Queue-style callers use `i64-deque-push-back` with
;# `i64-deque-pop-front`; double-ended callers may also use
;# `i64-deque-push-front` and `i64-deque-pop-back`.
;#
;# The backing array is active-arena owned. Mutating operations that may grow
;# the backing array return the updated deque and callers must thread that
;# value forward, matching `stdlib/vector.tl` and `stdlib/hashmap.tl`.
;# Empty pops return an explicit enum and peeks use caller fallbacks.
;#
;# Usage: `(import stdlib.queue)`
;#
;# ```typelisp
;# (import stdlib.queue)
;# (define (main) : i64
;#   (let
;#     [q : queue.I64Deque
;#       (queue.i64-deque-push-back
;#         (queue.i64-deque-push-back (queue.i64-deque-new) 10)
;#         32)]
;#     (queue.i64-deque-peek-front q 0)))
;# ```
;: A growable circular deque: `slots` holds capacity elements, `head` points to
;: the first live element, and `len` is the live element count.
(module stdlib.queue)

(defstruct I64Deque
  (slots (Array i64))
  (head i64)
  (len i64))

;: Result of popping from either end: the removed value plus the updated deque,
;: or `Empty` when the deque had no elements.
(defenum I64DequePop
  (I64DequePopEmpty)
  (I64DequePopOk i64 I64Deque))

;: The deque's backing array. Only `len` logical elements are live.
(define (i64-deque-slots [q : I64Deque]) : (Array i64)
  (struct-get q slots))

;: Logical index of the first live element in `slots`.
(define (i64-deque-head [q : I64Deque]) : i64
  (struct-get q head))

;: Number of live elements.
(define (i64-deque-len [q : I64Deque]) : i64
  (struct-get q len))

;: Number of slots in the backing array.
(define (i64-deque-capacity [q : I64Deque]) : i64
  (array-length (stdlib.queue.i64-deque-slots q)))

;: True when the deque holds no live elements.
(define (i64-deque-is-empty? [q : I64Deque]) : bool
  (<= (stdlib.queue.i64-deque-len q) 0))

;: Create an empty deque with backing capacity `capacity`. Non-positive
;: capacity is clamped to 1 so growth is always possible.
(define (i64-deque-with-capacity [capacity : i64]) : I64Deque
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (I64Deque (make-array i64 cap) 0 0)))

;: Create an empty deque with a small default capacity.
(define (i64-deque-new) : I64Deque
  (stdlib.queue.i64-deque-with-capacity 4))

;: Advance a physical slot index by one, wrapping around `capacity`.
(define (i64-deque-next-index [index : i64] [capacity : i64]) : i64
  (% (+ index 1) capacity))

;: Move a physical slot index back by one, wrapping around `capacity`.
(define (i64-deque-prev-index [index : i64] [capacity : i64]) : i64
  (if (<= index 0)
    (- capacity 1)
    (- index 1)))

;: Convert a logical live-element offset into a physical slot index.
(define (i64-deque-physical-index [q : I64Deque] [offset : i64]) : i64
  (%
    (+ (stdlib.queue.i64-deque-head q) offset)
    (stdlib.queue.i64-deque-capacity q)))

;: Read logical element `index`, returning `fallback` when `index` is out of
;: the live range `[0, len)`.
(define (i64-deque-get [q : I64Deque] [index : i64] [fallback : i64]) : i64
  (if (if (>= index 0)
    (< index (stdlib.queue.i64-deque-len q))
    false)
    (array-ref
      (stdlib.queue.i64-deque-slots q)
      (stdlib.queue.i64-deque-physical-index q index))
    fallback))

;: Read the front element, or `fallback` when empty.
(define (i64-deque-peek-front [q : I64Deque] [fallback : i64]) : i64
  (stdlib.queue.i64-deque-get q 0 fallback))

;: Read the back element, or `fallback` when empty.
(define (i64-deque-peek-back [q : I64Deque] [fallback : i64]) : i64
  (stdlib.queue.i64-deque-get q (- (stdlib.queue.i64-deque-len q) 1) fallback))

;: Copy live logical elements from `q` into `dst`, normalized so the first live
;: element lands at index 0.
(define (i64-deque-copy-live [dst : (Array i64)] [q : I64Deque] [index : i64]) : unit
  (if (>= index (stdlib.queue.i64-deque-len q))
    unit
    (begin
      (array-set!
        dst
        index
        (array-ref
          (stdlib.queue.i64-deque-slots q)
          (stdlib.queue.i64-deque-physical-index q index)))
      (stdlib.queue.i64-deque-copy-live dst q (+ index 1)))))

;: Return a copy of `q` with twice the capacity and `head` reset to 0.
(define (i64-deque-grow [q : I64Deque]) : I64Deque
  (let
    [n : i64 (stdlib.queue.i64-deque-len q)]
    [bigger : (Array i64)
      (make-array i64 (* (stdlib.queue.i64-deque-capacity q) 2))]
    (begin
      (stdlib.queue.i64-deque-copy-live bigger q 0)
      (I64Deque bigger 0 n))))

;: Append `value` to the back, growing first when full. Returns the updated
;: deque because growth may allocate a new backing array.
(define (i64-deque-push-back [q : I64Deque] [value : i64]) : I64Deque
  (if (< (stdlib.queue.i64-deque-len q) (stdlib.queue.i64-deque-capacity q))
    (let
      [slots : (Array i64) (stdlib.queue.i64-deque-slots q)]
      [tail : i64
        (stdlib.queue.i64-deque-physical-index q (stdlib.queue.i64-deque-len q))]
      (begin
        (array-set! slots tail value)
        (I64Deque
          slots
          (stdlib.queue.i64-deque-head q)
          (+ (stdlib.queue.i64-deque-len q) 1))))
    (stdlib.queue.i64-deque-push-back (stdlib.queue.i64-deque-grow q) value)))

;: Push `value` to the front, growing first when full. Returns the updated
;: deque because growth may allocate a new backing array.
(define (i64-deque-push-front [q : I64Deque] [value : i64]) : I64Deque
  (if (< (stdlib.queue.i64-deque-len q) (stdlib.queue.i64-deque-capacity q))
    (let
      [slots : (Array i64) (stdlib.queue.i64-deque-slots q)]
      [new-head : i64
        (stdlib.queue.i64-deque-prev-index
          (stdlib.queue.i64-deque-head q)
          (stdlib.queue.i64-deque-capacity q))]
      (begin
        (array-set! slots new-head value)
        (I64Deque slots new-head (+ (stdlib.queue.i64-deque-len q) 1))))
    (stdlib.queue.i64-deque-push-front (stdlib.queue.i64-deque-grow q) value)))

;: Remove and return the front element together with the updated deque.
(define (i64-deque-pop-front [q : I64Deque]) : I64DequePop
  (if (<= (stdlib.queue.i64-deque-len q) 0)
    stdlib.queue.I64DequePopEmpty
    (let
      [value : i64
        (array-ref
          (stdlib.queue.i64-deque-slots q)
          (stdlib.queue.i64-deque-head q))]
      [new-len : i64 (- (stdlib.queue.i64-deque-len q) 1)]
      (I64DequePopOk
        value
        (I64Deque
          (stdlib.queue.i64-deque-slots q)
          (if (= new-len 0)
            0
            (stdlib.queue.i64-deque-next-index
              (stdlib.queue.i64-deque-head q)
              (stdlib.queue.i64-deque-capacity q)))
          new-len)))))

;: Remove and return the back element together with the updated deque.
(define (i64-deque-pop-back [q : I64Deque]) : I64DequePop
  (if (<= (stdlib.queue.i64-deque-len q) 0)
    stdlib.queue.I64DequePopEmpty
    (let
      [last-index : i64
        (stdlib.queue.i64-deque-physical-index
          q
          (- (stdlib.queue.i64-deque-len q) 1))]
      [new-len : i64 (- (stdlib.queue.i64-deque-len q) 1)]
      (I64DequePopOk
        (array-ref (stdlib.queue.i64-deque-slots q) last-index)
        (I64Deque
          (stdlib.queue.i64-deque-slots q)
          (if (= new-len 0)
            0
            (stdlib.queue.i64-deque-head q))
          new-len)))))

(test
  i64-deque-api
  (let
    [fail : (-> unit)
      (lambda () : unit
        (begin
          (/ 1 0)
          unit))]
    (begin
      (let
        [empty : I64Deque (stdlib.queue.i64-deque-with-capacity 2)]
        (begin
          (if (= (stdlib.queue.i64-deque-len empty) 0)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-capacity empty) 2)
            unit
            (fail))
          (if (stdlib.queue.i64-deque-is-empty? empty)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-peek-front empty -1) -1)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-peek-back empty -1) -1)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-get empty 0 -1) -1)
            unit
            (fail))
          (if (=
            (stdlib.queue.i64-deque-capacity
              (stdlib.queue.i64-deque-with-capacity 0))
            1)
            unit
            (fail))))
      (let
        [q3 : I64Deque
          (stdlib.queue.i64-deque-push-back
            (stdlib.queue.i64-deque-push-back
              (stdlib.queue.i64-deque-push-back
                (stdlib.queue.i64-deque-with-capacity 3)
                10)
              20)
            30)]
        (begin
          (if (= (stdlib.queue.i64-deque-len q3) 3)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-peek-front q3 -1) 10)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-peek-back q3 -1) 30)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-get q3 1 -1) 20)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-get q3 -1 -1) -1)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-get q3 3 -1) -1)
            unit
            (fail))
          (match (stdlib.queue.i64-deque-pop-front q3)
            [(I64DequePopOk value1 q2)
              (begin
                (if (= value1 10)
                  unit
                  (fail))
                (if (= (stdlib.queue.i64-deque-peek-front q2 -1) 20)
                  unit
                  (fail))
                (match (stdlib.queue.i64-deque-pop-front q2)
                  [(I64DequePopOk value2 _)
                    (if (= value2 20)
                      unit
                      (fail))]
                  [(I64DequePopEmpty) (fail)]))]
            [(I64DequePopEmpty) (fail)])))
      (let
        [base : I64Deque
          (stdlib.queue.i64-deque-push-back
            (stdlib.queue.i64-deque-push-back
              (stdlib.queue.i64-deque-push-back
                (stdlib.queue.i64-deque-with-capacity 3)
                1)
              2)
            3)]
        (match (stdlib.queue.i64-deque-pop-front base)
          [(I64DequePopOk _ rest)
            (let
              [wrapped : I64Deque (stdlib.queue.i64-deque-push-back rest 4)]
              [grown : I64Deque (stdlib.queue.i64-deque-push-back wrapped 5)]
              (begin
                (if (= (stdlib.queue.i64-deque-capacity grown) 6)
                  unit
                  (fail))
                (if (= (stdlib.queue.i64-deque-len grown) 4)
                  unit
                  (fail))
                (if (= (stdlib.queue.i64-deque-get grown 0 -1) 2)
                  unit
                  (fail))
                (if (= (stdlib.queue.i64-deque-get grown 1 -1) 3)
                  unit
                  (fail))
                (if (= (stdlib.queue.i64-deque-get grown 2 -1) 4)
                  unit
                  (fail))
                (if (= (stdlib.queue.i64-deque-get grown 3 -1) 5)
                  unit
                  (fail))
                (if (= (stdlib.queue.i64-deque-peek-front grown -1) 2)
                  unit
                  (fail))
                (if (= (stdlib.queue.i64-deque-peek-back grown -1) 5)
                  unit
                  (fail))))]
          [(I64DequePopEmpty) (fail)]))
      (let
        [dq : I64Deque
          (stdlib.queue.i64-deque-push-front
            (stdlib.queue.i64-deque-push-back
              (stdlib.queue.i64-deque-with-capacity 2)
              20)
            10)]
        (begin
          (if (= (stdlib.queue.i64-deque-get dq 0 -1) 10)
            unit
            (fail))
          (if (= (stdlib.queue.i64-deque-get dq 1 -1) 20)
            unit
            (fail))
          (match (stdlib.queue.i64-deque-pop-back dq)
            [(I64DequePopOk back-value after-back)
              (begin
                (if (= back-value 20)
                  unit
                  (fail))
                (match (stdlib.queue.i64-deque-pop-front after-back)
                  [(I64DequePopOk front-value drained)
                    (begin
                      (if (= front-value 10)
                        unit
                        (fail))
                      (if (stdlib.queue.i64-deque-is-empty? drained)
                        unit
                        (fail))
                      (let
                        [again : I64Deque
                          (stdlib.queue.i64-deque-push-back drained 99)]
                        (begin
                          (if (= (stdlib.queue.i64-deque-len again) 1)
                            unit
                            (fail))
                          (if (=
                            (stdlib.queue.i64-deque-peek-front again -1)
                            99)
                            unit
                            (fail)))))]
                  [(I64DequePopEmpty) (fail)]))]
            [(I64DequePopEmpty) (fail)])))
      (match (stdlib.queue.i64-deque-pop-front (stdlib.queue.i64-deque-new))
        [(I64DequePopEmpty) unit]
        [(I64DequePopOk _ _) (fail)])
      (match (stdlib.queue.i64-deque-pop-back (stdlib.queue.i64-deque-new))
        [(I64DequePopEmpty) unit]
        [(I64DequePopOk _ _) (fail)]))))

;# Dotted-module migration: preserve the pre-module flat stdlib surface.
(export
  (value i64-deque-slots)
  (value i64-deque-head)
  (value i64-deque-len)
  (value i64-deque-capacity)
  (value i64-deque-is-empty?)
  (value i64-deque-with-capacity)
  (value i64-deque-new)
  (value i64-deque-next-index)
  (value i64-deque-prev-index)
  (value i64-deque-physical-index)
  (value i64-deque-get)
  (value i64-deque-peek-front)
  (value i64-deque-peek-back)
  (value i64-deque-copy-live)
  (value i64-deque-grow)
  (value i64-deque-push-back)
  (value i64-deque-push-front)
  (value i64-deque-pop-front)
  (value i64-deque-pop-back)
  (type I64Deque)
  (type I64DequePop)
  (constructor I64Deque)
  (field I64Deque slots)
  (field I64Deque head)
  (field I64Deque len)
  (variant I64DequePopEmpty)
  (variant I64DequePopOk))