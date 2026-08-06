;; Rust-style lifetime shortening is a checked type coercion. It changes only
;; static lifetime arguments; the represented values and ABI stay identical.
(defstruct SharedView
  (:lifetimes source)
  (value (& source i64)))

(defenum SharedChoice
  (:lifetimes source)
  (Borrowed (& source i64))
  (Empty))

(defstruct Consumer
  (:lifetimes source)
  (apply (-> (& source i64) i64)))

(define (read-ref [value : (& source i64)]) : i64
  (deref value))

(define (choose-left [left : (& same i64)] [_right : (& same i64)]) : (&
    same
    i64)
  left)

(define (same-text-owner [left : (& same str)] [right : (& same str)]) : i64
  0)

(define (same-consumer-owner [left : (Consumer same)] [right : (Consumer same)]) : i64
  0)

(define (auto-borrow-shortest [left : String] [right : String]) : i64
  (same-text-owner left right))

(define (exercise
  [shared : (& outer i64)]
  [mutable : (&mut outer i64)]
  [view : (SharedView outer)]
  [choice : (SharedChoice outer)]
  [tuple-value : (Tuple (& outer i64))]
  [array-value : (Array (& outer i64) 1)]
  [boxed : (Box (& outer i64))]
  [raw : (Ptr (& outer i64))]
  [slice : (& outer (Slice i64))]
  [producer : (-> (& outer i64))]) : i64
  (let
    [short-owner : i64 0]
    [short-shared : (& short-owner i64) shared]
    [short-mutable : (&mut short-owner i64) mutable]
    [short-view : (SharedView short-owner) view]
    [short-choice : (SharedChoice short-owner) choice]
    [constructed-view : (SharedView short-owner) (SharedView shared)]
    [constructed-choice : (SharedChoice short-owner)
      (SharedChoice.Borrowed shared)]
    [short-tuple : (Tuple (& short-owner i64)) tuple-value]
    [short-array : (Array (& short-owner i64) 1) array-value]
    [short-box : (Box (& short-owner i64)) boxed]
    [short-raw : (Ptr (& short-owner i64)) raw]
    [short-slice : (& short-owner (Slice i64)) slice]
    [short-producer : (-> (& short-owner i64)) producer]
    [short-consumer : (-> (& short-owner i64) i64)
      (lambda ([value : (& short-owner i64)]) : i64
        (deref value))]
    [outer-consumer : (-> (& outer i64) i64) short-consumer]
    [nominal-consumer : (Consumer short-owner) (Consumer short-consumer)]
    [wide-nominal-consumer : (Consumer outer) nominal-consumer]
    [contravariant-call : i64
      (same-consumer-owner nominal-consumer wide-nominal-consumer)]
    [contravariant-call-reversed : i64
      (same-consumer-owner wide-nominal-consumer nominal-consumer)]
    [chosen : (& short-owner i64) (choose-left shared short-shared)]
    [chosen-reversed : (& short-owner i64) (choose-left short-shared shared)]
    [joined : (& short-owner i64)
      (if (= (deref short-shared) 42)
        shared
        short-shared)]
    [matched : (& short-owner i64)
      (match choice
        [(SharedChoice.Borrowed value) value]
        [(SharedChoice.Empty) short-shared])]
    [captured : (-> (& short-owner i64))
      (lambda () : (& short-owner i64)
        shared)]
    [slot : (& short-owner i64) short-shared]
    (begin
      (set! slot shared)
      0)))

(define (main) : i64
  42)