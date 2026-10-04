;; Handle slots are borrowed as their descriptor, while inline payloads retain
;; their address. Shared/mutable and nested paths must agree with owned reads.
(import stdlib.io)
(import stdlib.string)
(import stdlib.byte_buf)

(defenum Payload
  (Values (__tl_dyn-array i64))
  (Text String)
  (Empty))

(defenum Nested
  (Pair (Tuple (__tl_dyn-array i64) i64))
  (Wrap Payload))

(defenum BytePayload
  (:lifetimes data)
  (View (& data bytes)))

(defstruct Holder
  (values (__tl_dyn-array i64)))

(define (array-score [values : (& values (__tl_dyn-array i64))]) : i64
  (+ (array-length values) (array-ref values 2)))

(define (payload-score [payload : (& Payload)]) : i64
  (match payload
    [(Values values) (array-score values)]
    [(Text text) (string.string-length text)]
    [Empty 0]))

(define (payload-mut-score [payload : (&mut Payload)]) : i64
  ;; Enum patterns use a shared reborrow of the mutable owner.
  (match (& payload)
    [(Values values) (array-score values)]
    [(Text text) (string.string-length text)]
    [Empty 0]))

(define (owned-score [payload : Payload]) : i64
  (match payload
    [(Values values) (array-score (& values))]
    [(Text text) (string.string-length (& text))]
    [Empty 0]))

(define (nested-score [payload : (& Nested)]) : i64
  (match payload
    [(Pair (tuple values extra)) (+ (array-score values) (deref extra))]
    [(Wrap value) (payload-score value)]))

(define (bytes-score [payload : (& (BytePayload data))]) : i64
  (match payload
    [(View view) (byte_buf.bytes-length (deref view))]))

(define (make-values) : (__tl_dyn-array i64)
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    (set! (array-ref values 2) 38)
    values))

(define (main) : i64
  (let
    [grid : (__tl_dyn-array (__tl_dyn-array i64))
      (__tl_make-array (__tl_dyn-array i64) 1)]
    (set! (array-ref grid 0) (make-values))
    (unless (= (array-score (& (array-ref grid 0))) 42) (return 1))
    (let
      [mutable : (&mut grid (__tl_dyn-array i64)) (&mut (array-ref grid 0))]
      (set! (array-ref mutable 2) 39))
    (unless (= (array-score (& (array-ref grid 0))) 43) (return 2))
    (when
      (string.eq (io.arg 1) "bounds")
      (let
        [view : (& grid (__tl_dyn-array i64)) (& (array-ref grid 0))]
        (return (array-ref view 4))))
    (let
      [fixed : (Array (__tl_dyn-array i64) 1) (array (make-values))]
      (unless (= (array-score (& (array-ref fixed 0))) 42) (return 3))
      (let
        [mutable : (&mut fixed (__tl_dyn-array i64)) (&mut (array-ref fixed 0))]
        (set! (array-ref mutable 2) 40))
      (unless (= (array-score (& (array-ref fixed 0))) 44) (return 4))
      (let
        [slice : (& fixed (Slice (__tl_dyn-array i64)))
          (slice-view (& fixed) 0 1)]
        (unless (= (array-score (& (array-ref slice 0))) 44) (return 5))))
    (let
      [payload : Payload (Values (make-values))]
      (unless (= (payload-score (& payload)) 42) (return 6))
      (unless (= (payload-mut-score (&mut payload)) 42) (return 7))
      (unless (= (owned-score payload) 42) (return 8)))
    (let
      [tupled : Nested (Pair (tuple (make-values) 1))]
      (unless (= (nested-score (& tupled)) 43) (return 9)))
    (let
      [nested : Nested (Wrap (Values (make-values)))]
      (unless (= (nested-score (& nested)) 42) (return 10)))
    (let
      [holder : Holder (Holder (make-values))]
      (unless (= (array-score (& holder.values)) 42) (return 11)))
    (let
      [pair : (Tuple (__tl_dyn-array i64) i64) (tuple (make-values) 7)]
      (unless (= (array-length (& (tuple-ref pair 0))) 4) (return 16))
      (let
        [mutable : (&mut pair (__tl_dyn-array i64)) (&mut (tuple-ref pair 0))]
        (set! (array-ref mutable 2) 40))
      (unless (= (array-score (& (tuple-ref pair 0))) 44) (return 17)))
    (let
      [text : String "hello"]
      [view : (BytePayload text) (View (byte_buf.str-as-bytes (& text)))]
      (unless (= (bytes-score (& view)) 5) (return 12)))
    (let
      [text : Payload (Text "hello")]
      (unless (= (payload-score (& text)) 5) (return 13))
      (unless (= (payload-mut-score (&mut text)) 5) (return 14)))
    (let
      [empty : Payload
        (if (string.eq (io.arg 1) "values")
          (Values (make-values))
          Empty)]
      [i : i64 0]
      [sum : i64 0]
      (while (< i 4)
        (set! sum (+ sum (payload-score (& empty))))
        (set! i (+ i 1)))
      (unless
        (=
          sum
          (if (string.eq (io.arg 1) "values")
            168
            0))
        (return 15)))
    42))