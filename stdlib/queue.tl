;;;; Dynamic `i64` queue/deque (collections v1, #1549).
;;;;
;;;; A growable, owned double-ended queue of `i64` values backed by a circular
;;;; `(Array i64)`. Queue-style callers use `i64-deque-push-back` with
;;;; `i64-deque-pop-front`; double-ended callers may also use
;;;; `i64-deque-push-front` and `i64-deque-pop-back`.
;;;;
;;;; The backing array is active-arena owned. Mutating operations that may grow
;;;; the backing array return the updated deque and callers must thread that
;;;; value forward, matching `stdlib/vector.tl` and `stdlib/hashmap.tl`.
;;;; Empty pops return an explicit enum and peeks use caller fallbacks.
;;;;
;;;; Usage: `(import "stdlib/queue.tl")`
;;;;
;;;; ```typelisp
;;;; (import "stdlib/queue.tl")
;;;; (define (main) : i64
;;;;   (let
;;;;     [q : I64Deque
;;;;       (i64-deque-push-back
;;;;         (i64-deque-push-back (i64-deque-new) 10)
;;;;         32)]
;;;;     (i64-deque-peek-front q 0)))
;;;; ```
;;; A growable circular deque: `slots` holds capacity elements, `head` points to
;;; the first live element, and `len` is the live element count.
(defstruct I64Deque
  (slots (Array i64))
  (head i64)
  (len i64))

;;; Result of popping from either end: the removed value plus the updated deque,
;;; or `Empty` when the deque had no elements.
(defenum I64DequePop
  (I64DequePopEmpty)
  (I64DequePopOk i64 I64Deque))

;;; The deque's backing array. Only `len` logical elements are live.
(define (i64-deque-slots [q : I64Deque]) : (Array i64)
  (struct-get q slots))

;;; Logical index of the first live element in `slots`.
(define (i64-deque-head [q : I64Deque]) : i64
  (struct-get q head))

;;; Number of live elements.
(define (i64-deque-len [q : I64Deque]) : i64
  (struct-get q len))

;;; Number of slots in the backing array.
(define (i64-deque-capacity [q : I64Deque]) : i64
  (array-length (i64-deque-slots q)))

;;; True when the deque holds no live elements.
(define (i64-deque-is-empty? [q : I64Deque]) : bool
  (<= (i64-deque-len q) 0))

;;; Create an empty deque with backing capacity `capacity`. Non-positive
;;; capacity is clamped to 1 so growth is always possible.
(define (i64-deque-with-capacity [capacity : i64]) : I64Deque
  (let
    [cap : i64
      (if (< capacity 1)
        1
        capacity)]
    (I64Deque (make-array i64 cap) 0 0)))

;;; Create an empty deque with a small default capacity.
(define (i64-deque-new) : I64Deque
  (i64-deque-with-capacity 4))

;;; Advance a physical slot index by one, wrapping around `capacity`.
(define (i64-deque-next-index [index : i64] [capacity : i64]) : i64
  (% (+ index 1) capacity))

;;; Move a physical slot index back by one, wrapping around `capacity`.
(define (i64-deque-prev-index [index : i64] [capacity : i64]) : i64
  (if (<= index 0)
    (- capacity 1)
    (- index 1)))

;;; Convert a logical live-element offset into a physical slot index.
(define (i64-deque-physical-index [q : I64Deque] [offset : i64]) : i64
  (% (+ (i64-deque-head q) offset) (i64-deque-capacity q)))

;;; Read logical element `index`, returning `fallback` when `index` is out of
;;; the live range `[0, len)`.
(define (i64-deque-get [q : I64Deque] [index : i64] [fallback : i64]) : i64
  (if (if (>= index 0)
    (< index (i64-deque-len q))
    false)
    (array-ref (i64-deque-slots q) (i64-deque-physical-index q index))
    fallback))

;;; Read the front element, or `fallback` when empty.
(define (i64-deque-peek-front [q : I64Deque] [fallback : i64]) : i64
  (i64-deque-get q 0 fallback))

;;; Read the back element, or `fallback` when empty.
(define (i64-deque-peek-back [q : I64Deque] [fallback : i64]) : i64
  (i64-deque-get q (- (i64-deque-len q) 1) fallback))

;;; Copy live logical elements from `q` into `dst`, normalized so the first live
;;; element lands at index 0.
(define (i64-deque-copy-live [dst : (Array i64)] [q : I64Deque] [index : i64]) : unit
  (if (>= index (i64-deque-len q))
    unit
    (begin
      (array-set!
        dst
        index
        (array-ref (i64-deque-slots q) (i64-deque-physical-index q index)))
      (i64-deque-copy-live dst q (+ index 1)))))

;;; Return a copy of `q` with twice the capacity and `head` reset to 0.
(define (i64-deque-grow [q : I64Deque]) : I64Deque
  (let
    [n : i64 (i64-deque-len q)]
    [bigger : (Array i64) (make-array i64 (* (i64-deque-capacity q) 2))]
    (begin
      (i64-deque-copy-live bigger q 0)
      (I64Deque bigger 0 n))))

;;; Append `value` to the back, growing first when full. Returns the updated
;;; deque because growth may allocate a new backing array.
(define (i64-deque-push-back [q : I64Deque] [value : i64]) : I64Deque
  (if (< (i64-deque-len q) (i64-deque-capacity q))
    (let
      [slots : (Array i64) (i64-deque-slots q)]
      [tail : i64 (i64-deque-physical-index q (i64-deque-len q))]
      (begin
        (array-set! slots tail value)
        (I64Deque slots (i64-deque-head q) (+ (i64-deque-len q) 1))))
    (i64-deque-push-back (i64-deque-grow q) value)))

;;; Push `value` to the front, growing first when full. Returns the updated
;;; deque because growth may allocate a new backing array.
(define (i64-deque-push-front [q : I64Deque] [value : i64]) : I64Deque
  (if (< (i64-deque-len q) (i64-deque-capacity q))
    (let
      [slots : (Array i64) (i64-deque-slots q)]
      [new-head : i64
        (i64-deque-prev-index (i64-deque-head q) (i64-deque-capacity q))]
      (begin
        (array-set! slots new-head value)
        (I64Deque slots new-head (+ (i64-deque-len q) 1))))
    (i64-deque-push-front (i64-deque-grow q) value)))

;;; Remove and return the front element together with the updated deque.
(define (i64-deque-pop-front [q : I64Deque]) : I64DequePop
  (if (<= (i64-deque-len q) 0)
    (I64DequePopEmpty)
    (let
      [value : i64 (array-ref (i64-deque-slots q) (i64-deque-head q))]
      [new-len : i64 (- (i64-deque-len q) 1)]
      (I64DequePopOk
        value
        (I64Deque
          (i64-deque-slots q)
          (if (= new-len 0)
            0
            (i64-deque-next-index (i64-deque-head q) (i64-deque-capacity q)))
          new-len)))))

;;; Remove and return the back element together with the updated deque.
(define (i64-deque-pop-back [q : I64Deque]) : I64DequePop
  (if (<= (i64-deque-len q) 0)
    (I64DequePopEmpty)
    (let
      [last-index : i64 (i64-deque-physical-index q (- (i64-deque-len q) 1))]
      [new-len : i64 (- (i64-deque-len q) 1)]
      (I64DequePopOk
        (array-ref (i64-deque-slots q) last-index)
        (I64Deque
          (i64-deque-slots q)
          (if (= new-len 0)
            0
            (i64-deque-head q))
          new-len)))))