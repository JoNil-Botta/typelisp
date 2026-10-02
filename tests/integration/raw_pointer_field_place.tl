;; `(deref p).field` through a raw pointer, inside `unsafe`: reads load just
;; that field and `set!` stores just that field, at its offset from `p`, with
;; no copy of the pointee (SPEC section 5.20). The state block below is
;; reached the way the compiler reaches its opaque state handles: a heap cell
;; whose address is kept as an integer.
(import stdlib.string)

(defstruct Inner
  (a i64)
  (b i32)
  (flag bool))

;; Small enough to be carried in registers as a value, but a raw pointer
;; reaches it in memory.
(defstruct Pair
  (lo i32)
  (hi i32))

(defstruct State
  (count i64)
  (name String)
  (inner Inner)
  (slots (Array i64 4))
  (items (__tl_dyn-array i64))
  (pair Pair)
  (small i32)
  (tag u8)
  (total i64))

(define (state-ptr [address : i64]) : (MutPtr State)
  (unsafe
    (int->ptr (cast address : u64) : (MutPtr State))))

(define (state-view [address : i64]) : (Ptr State)
  (unsafe
    (int->ptr (cast address : u64) : (Ptr State))))

(define (new-state-address) : i64
  (let
    [cell : (__tl_dyn-array State) (__tl_make-array State 1)]
    (begin
      (set!
        (array-ref cell 0)
        (State
          0
          "ab"
          (Inner 5 6 false)
          (array 1 2 3 4)
          (__tl_make-array i64 3)
          (Pair 7 8)
          0
          0
          0))
      (cast
        (unsafe
          (ptr->int (__tl_array-data cell)))
        : i64))))

;; Several single-field stores and loads through one pointer; large enough to
;; stay out of line at opt 2, so its assembly shape can be checked.
(define (record! [address : i64] [value : i64] [small : i32] [tag : u8]) : unit
  (let
    [p : (MutPtr State) (state-ptr address)]
    (unsafe
      (begin
        (set! (deref p).count (+ (deref p).count 1))
        (set! (deref p).total (+ (deref p).total value))
        (set! (deref p).small small)
        (set! (deref p).tag tag)
        (set! (deref p).inner.a (* (deref p).inner.a 2))
        (set! (deref p).inner.flag (> value 0))))))

;; Reads through a read-only pointer.
(define (score [address : i64]) : i64
  (let
    [p : (Ptr State) (state-view address)]
    (unsafe
      (+
        (deref p).count
        (deref p).total
        (cast (deref p).small : i64)
        (cast (deref p).tag : i64)
        (deref p).inner.a
        (if (deref p).inner.flag
          1
          0)))))

(define (rename! [address : i64] [name : String]) : unit
  (unsafe
    (set! (deref (state-ptr address)).name name)))

(define (name-length [address : i64]) : i64
  (let
    [name : String
      (unsafe
        (deref (state-view address)).name)]
    (string.string-length (& name))))

(define (pair-sum [address : i64]) : i64
  (unsafe
    (+
      (cast (deref (state-view address)).pair.lo : i64)
      (cast (deref (state-view address)).pair.hi : i64))))

;; The pointer operand is evaluated before the stored value, as for
;; `ptr-write!`.
(define (ordered-store [address : i64]) : i64
  (let
    [order : i64 0]
    (begin
      (unsafe
        (set!
          (deref
            (begin
              (set! order (* order 10))
              (set! order (+ order 1))
              (state-ptr address))).count
          (begin
            (set! order (* order 10))
            (set! order (+ order 2))
            order)))
      order)))

(define (check [ok : bool] [points : i64]) : i64
  (if ok
    points
    0))

(define (main) : i64
  (let
    [address : i64 (new-state-address)]
    [p : (MutPtr State) (state-ptr address)]
    [old-name : String
      (unsafe
        (deref p).name)]
    (begin
      (record! address 10 3 4)
      (record! address 20 5 6)
      (rename! address "hello")
      (unsafe
        (begin
          (set! (array-ref (deref p).slots 2) 30)
          (set! (array-ref (deref p).items 1) 40)
          (set! (deref p).pair.hi 9)
          (set! (deref p).inner.b (+ (deref p).inner.b 1))))
      (let
        [state : State
          (unsafe
            (ptr-read (state-view address)))]
        (+
          (check (= (score address) (+ 2 30 5 6 20 1)) 3)
          (check (= state.count 2) 3)
          (check (= state.total 30) 3)
          (check (= state.inner.a 20) 3)
          (check (= state.inner.b 7) 3)
          (check (= (name-length address) 5) 3)
          ;; The overwritten String is not dropped: a copy read earlier stays
          ;; valid, as with `ptr-write!`.
          (check (= (string.string-length (& old-name)) 2) 3)
          (check
            (=
              (unsafe
                (array-ref (deref p).slots 2))
              30)
            3)
          (check (= (array-ref state.slots 3) 4) 3)
          (check
            (=
              (unsafe
                (array-ref (deref p).items 1))
              40)
            3)
          (check (= (pair-sum address) 16) 3)
          (check (= (ordered-store address) 12) 3)
          (check (= (score address) (+ 12 30 5 6 20 1)) 3)
          (check
            (=
              (unsafe
                (deref p).pair.lo)
              7)
            3))))))