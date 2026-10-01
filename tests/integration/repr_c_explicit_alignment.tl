;; #7445: explicit `(:align N)` on `(:repr c)` structs and their fields. Every
;; layout query must equal what C reports for the `_Alignas` equivalents in
;; benchmarks/repr_c_explicit_alignment/baseline.c, and C reading and writing
;; through pointers, and taking and returning the structs by value, must see the
;; same field offsets. main returns 42 when all
;; agree and a distinct code for the first disagreement.
(defstruct CanFrame
  (:repr c)
  (can-id u32)
  (len u8)
  (pad u8)
  (res0 u8)
  (len8-dlc u8)
  (data (Array u8 8) (:align 8)))

;; Struct-level alignment rounds the size up; field-level alignment moves only
;; that field. The metadata order is free before the fields.
(defstruct Prefix
  (:align 8)
  (:repr c)
  (kind u8)
  (schedule u8 (:align 8)))

;; Ordinary structs and fixed arrays take the effective alignment.
(defstruct Outer
  (tag u8)
  (inner Prefix)
  (tail u16))

(defstruct Shelf
  (:repr c)
  (items (Array Prefix 3))
  (after u8))

(defstruct Halves
  (:repr c)
  (a u8)
  (b u16 (:align 4))
  (c u8))

(extern (align-c-layout [which : i64]) : i64 (:symbol "tl_align_c_layout"))
(extern (align-c-fill-frame [frame : (MutPtr CanFrame)]) : i64 (:symbol "tl_align_c_fill_frame"))
(extern (align-c-sum-shelf [shelf : (MutPtr Shelf)]) : i64 (:symbol "tl_align_c_sum_shelf"))
(extern (align-c-sum-halves [halves : (MutPtr Halves)]) : i64 (:symbol "tl_align_c_sum_halves"))
(extern (align-c-sum-outer [outer : (MutPtr Outer)]) : i64 (:symbol "tl_align_c_sum_outer"))
(extern (align-c-make-prefix [kind : i64] [schedule : i64]) : Prefix (:symbol "tl_align_c_make_prefix"))
(extern (align-c-prefix-value [prefix : Prefix]) : i64 (:symbol "tl_align_c_prefix_value"))
(extern (align-c-make-halves [a : i64] [b : i64] [c : i64]) : Halves (:symbol "tl_align_c_make_halves"))
(extern (align-c-halves-value [halves : Halves]) : i64 (:symbol "tl_align_c_halves_value"))

(define layouts : (Array i64 16)
  (array
    (comptime (size-of (type CanFrame)))
    (comptime (align-of (type CanFrame)))
    (comptime (offset-of (type CanFrame) data))
    (comptime (size-of (type Prefix)))
    (comptime (align-of (type Prefix)))
    (comptime (offset-of (type Prefix) schedule))
    (comptime (size-of (type Outer)))
    (comptime (align-of (type Outer)))
    (comptime (offset-of (type Outer) inner))
    (comptime (offset-of (type Outer) tail))
    (comptime (size-of (type Shelf)))
    (comptime (offset-of (type Shelf) after))
    (comptime (size-of (type Halves)))
    (comptime (align-of (type Halves)))
    (comptime (offset-of (type Halves) b))
    (comptime (offset-of (type Halves) c))))

(define (layouts-match? [which : i64]) : bool
  (if (>= which 16)
    true
    (and
      (= (array-ref layouts which) (align-c-layout which))
      (layouts-match? (+ which 1)))))

(define (declared-aligns-ok?) : bool
  (and
    (= (comptime (type-declared-align (type Prefix))) 8)
    (= (comptime (type-declared-align (type CanFrame))) 0)
    (= (comptime (type-declared-align (type Outer))) 0)
    (= (comptime (type-declared-align (type i64))) 0)
    (= (comptime (struct-field-declared-align (type CanFrame) 5)) 8)
    (= (comptime (struct-field-declared-align (type CanFrame) 0)) 0)
    (= (comptime (struct-field-declared-align (type Prefix) 1)) 8)
    (= (comptime (struct-field-declared-align (type Halves) 1)) 4)))

(define (main) : i64
  (let
    [frame : CanFrame
      (CanFrame
        (cast 0 : u32)
        (cast 0 : u8)
        (cast 0 : u8)
        (cast 0 : u8)
        (cast 0 : u8)
        (init : (Array u8 8)))]
    [shelf : Shelf
      (Shelf
        (array
          (Prefix (cast 1 : u8) (cast 2 : u8))
          (Prefix (cast 3 : u8) (cast 4 : u8))
          (Prefix (cast 5 : u8) (cast 6 : u8)))
        (cast 7 : u8))]
    [halves : Halves (Halves (cast 3 : u8) (cast 513 : u16) (cast 9 : u8))]
    [outer : Outer
      (Outer (cast 5 : u8) (Prefix (cast 6 : u8) (cast 7 : u8)) (cast 11 : u16))]
    (begin
      (unless (layouts-match? 0) (return 1))
      (unless (declared-aligns-ok?) (return 2))
      (unless
        (=
          (align-c-fill-frame
            (unsafe
              (ptr-addr-of frame)))
          77)
        (return 3))
      (unless (= frame.can-id (cast 291 : u32)) (return 4))
      (unless (= frame.len (cast 8 : u8)) (return 5))
      (unless (= (array-ref frame.data 0) (cast 1 : u8)) (return 6))
      (unless (= (array-ref frame.data 7) (cast 8 : u8)) (return 7))
      (unless
        (=
          (align-c-sum-shelf
            (unsafe
              (ptr-addr-of shelf)))
          (+ 7 (+ (+ 12 34) 56)))
        (return 8))
      (unless
        (=
          (align-c-sum-halves
            (unsafe
              (ptr-addr-of halves)))
          (+ 3 (+ (* 513 16) (* 9 4096))))
        (return 9))
      ;; An ordinary struct embedding an aligned one: C sees TypeLisp's
      ;; offsets, and TypeLisp reads its own fields back.
      (unless
        (=
          (align-c-sum-outer
            (unsafe
              (ptr-addr-of outer)))
          (+ 5 (+ (* 6 16) (+ (* 7 256) (* 11 4096)))))
        (return 10))
      (unless (= outer.inner.schedule (cast 7 : u8)) (return 11))
      (unless (= outer.tail (cast 11 : u16)) (return 12))
      ;; By value: C passes and returns these at TypeLisp's offsets. On SysV
      ;; `Prefix`'s `schedule` is alone in the second eightbyte.
      (let
        [made : Prefix (align-c-make-prefix 9 5)]
        (begin
          (unless (= made.kind (cast 9 : u8)) (return 13))
          (unless (= made.schedule (cast 5 : u8)) (return 14))))
      (unless
        (=
          (align-c-prefix-value (Prefix (cast 6 : u8) (cast 7 : u8)))
          (+ (* 6 16) 7))
        (return 15))
      (let
        [made : Halves (align-c-make-halves 3 513 9)]
        (begin
          (unless (= made.a (cast 3 : u8)) (return 16))
          (unless (= made.b (cast 513 : u16)) (return 17))
          (unless (= made.c (cast 9 : u8)) (return 18))))
      (unless
        (= (align-c-halves-value halves) (+ 3 (+ (* 513 16) (* 9 4096))))
        (return 19))
      42)))