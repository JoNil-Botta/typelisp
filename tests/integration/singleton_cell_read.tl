(import stdlib.string)

;; Macro expansion and source spans are transparent to the immediate-cell fold.
(defmacro (cell-read [value : Expr] [ty : Expr]) : Expr
  `(unsafe
    (ptr-read (ptr-cast (__tl_array-data (array ,value)) : (Ptr ,ty)))))

(defstruct Pair
  (a i64)
  (b i64))

(define calls : i64
  0)
(define global-word : i64
  10)

(define (counted [value : i64]) : i64
  (set! calls (+ (* calls 10) value))
  value)

(define (make-items) : (__tl_dyn-array i64)
  (__tl_make-array (ann 20 : i64) 22))

(define (write-word [ptr : (MutPtr i64)] [value : i64] [depth : i64]) : i64
  (if (> depth 0)
    (write-word ptr value (- depth 1))
    (begin
      (unsafe
        (ptr-write! ptr value))
      0)))

(define (mut-reference-cases [value : (&mut value i64)]) : bool
  (let
    [pair : Pair (Pair 17 25)]
    [alias : (MutPtr i64) (cell-read value (MutPtr i64))]
    [address : u64 (cell-read alias u64)]
    [pair-address : (Ptr Pair) (cell-read (& pair) (Ptr Pair))]
    [before : i64
      (unsafe
        (ptr-read (int->ptr address : (Ptr i64))))]
    (unsafe
      (ptr-write! alias 42))
    (let
      [after : i64
        (unsafe
          (ptr-read (cell-read alias (Ptr i64))))]
      [copy : Pair
        (unsafe
          (ptr-read pair-address))]
      (and (= before 40) (= after 42) (= (+ copy.a copy.b) 42)))))

(define (reference-cases) : bool
  (let
    [n : i64 40]
    [shared : (Ptr i64) (cell-read (& n) (Ptr i64))]
    [before : i64
      (unsafe
        (ptr-read shared))]
    [ok : bool (mut-reference-cases (&mut n))]
    (and ok (= before 40) (= n 42))))

(define (handle-cases) : bool
  (let
    [text : String "cell"]
    [text-view : String (cell-read (& text) String)]
    [items : (__tl_dyn-array i64) (make-items)]
    [items-view : (__tl_dyn-array i64)
      (cell-read (& items) (__tl_dyn-array i64))]
    [boxed : (Box i64) (cell-read (box 42) (Box i64))]
    [owned-text : String (cell-read "word" String)]
    [owned-items : (__tl_dyn-array i64)
      (cell-read (make-items) (__tl_dyn-array i64))]
    (set! (array-ref items 0) 21)
    (and
      (string.eq text-view "cell")
      (string.eq owned-text "word")
      (= (array-ref items-view 0) 21)
      (= (array-ref items-view 1) 22)
      (= (+ (array-ref owned-items 0) (array-ref owned-items 1)) 42)
      (= (deref boxed) 42))))

(define (ordered-cases) : bool
  (set! calls 0)
  (let
    [sum : i64 (+ (cell-read (counted 1) i64) (counted 2))]
    [n : i64 10]
    [direct : i64
      (+
        (cell-read n i64)
        (begin
          (set! n 20)
          1))]
    [ptr : (MutPtr i64)
      (unsafe
        (ptr-addr-of n))]
    [through-alias : i64 (+ (cell-read n i64) (write-word ptr 30 2))]
    [global-ptr : (MutPtr i64)
      (unsafe
        (ptr-addr-of global-word))]
    [global-before : i64
      (+ (cell-read global-word i64) (write-word global-ptr 50 2))]
    [later : i64 (cell-read global-word i64)]
    (and
      (= sum 3)
      (= calls 12)
      (= direct 11)
      (= through-alias 20)
      (= n 30)
      (= global-before 10)
      (= later 50))))

;; Reinterpretation preserves all bits, including negative zero and NaN payloads.
(define (float-roundtrip [bits : u64]) : u64
  (cell-read (cell-read bits f64) u64))

(define (float-cases) : bool
  (and
    (= (float-roundtrip 0x8000000000000000) 0x8000000000000000)
    (= (float-roundtrip 0x7ff8000000000042) 0x7ff8000000000042)
    (= (float-roundtrip 0xfff0000000000001) 0xfff0000000000001)
    (= (float-roundtrip 0x3ff0000000000000) 0x3ff0000000000000)
    (= (cell-read (ann -1 : i64) u64) 0xffffffffffffffff)))

(define (read-saved [ptr : (MutPtr i64)]) : i64
  (unsafe
    (ptr-read ptr)))

(define (fallback-cases) : bool
  (let
    [items : (Array i64 2) (array 17 25)]
    [slice : (& items (Slice i64)) (slice-view items 0 2)]
    [slice-copy : (& items (Slice i64)) (cell-read slice (& items (Slice i64)))]
    [saved-cell : (Array i64 1) (array 10)]
    [saved : (MutPtr i64)
      (unsafe
        (__tl_array-data saved-cell))]
    [before : i64 (read-saved saved)]
    (unsafe
      (ptr-write! saved 42))
    (and
      (= (array-length slice-copy) 2)
      (= (array-ref slice-copy 0) 17)
      (= (cell-read (ann 42 : i32) i32) 42)
      (= (cell-read (Pair 17 25) i64) 17)
      (= (cell-read (tuple (ann 17 : i64) (ann 25 : i64)) i64) 17)
      (=
        (unsafe
          (ptr-read
            (ptr-cast (__tl_array-data (array (ann 17 : i64) 25)) : (Ptr i64))))
        17)
      (=
        (unsafe
          (ptr-read (ptr-offset (__tl_array-data (array 17 25)) 1)))
        25)
      (= before 10)
      (= (read-saved saved) 42))))

(define (main) : i64
  (cond
    [(not (reference-cases)) 1]
    [(not (handle-cases)) 2]
    [(not (ordered-cases)) 3]
    [(not (float-cases)) 4]
    [(not (fallback-cases)) 5]
    [else 42]))