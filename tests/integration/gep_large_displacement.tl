;; Constant raw-pointer offsets retain their full width. Exported functions
;; keep each load/store/address shape present even when main inlines a call.
;; Main biases the input address so each wide offset lands on its small live
;; allocation; the adjacent-load pair is compile-only (its caller must provide
;; two valid locations). The native corpus runs opt0/1/2 on both targets.
(define (load-positive-boundary [p : (Ptr u8)])
  (:export-symbol "gep_load_positive_boundary") : u8
  (unsafe
    (ptr-read (ptr-offset p 2147483647))))

(define (store-positive-boundary [p : (MutPtr u8)] [value : u8])
  (:export-symbol "gep_store_positive_boundary") : unit
  (unsafe
    (ptr-write! (ptr-offset p 2147483647) value)))

(define (load-positive-wide [p : (Ptr u8)])
  (:export-symbol "gep_load_positive_wide") : u8
  (unsafe
    (ptr-read (ptr-offset p 2147483648))))

(define (store-positive-wide [p : (MutPtr u8)] [value : u8])
  (:export-symbol "gep_store_positive_wide") : unit
  (unsafe
    (ptr-write! (ptr-offset p 2147483648) value)))

(define (load-negative-boundary [p : (Ptr u8)])
  (:export-symbol "gep_load_negative_boundary") : u8
  (unsafe
    (ptr-read (ptr-offset p -2147483648))))

(define (store-negative-boundary [p : (MutPtr u8)] [value : u8])
  (:export-symbol "gep_store_negative_boundary") : unit
  (unsafe
    (ptr-write! (ptr-offset p -2147483648) value)))

(define (load-negative-wide [p : (Ptr u8)])
  (:export-symbol "gep_load_negative_wide") : u8
  (unsafe
    (ptr-read (ptr-offset p -2147483649))))

(define (store-negative-wide [p : (MutPtr u8)] [value : u8])
  (:export-symbol "gep_store_negative_wide") : unit
  (unsafe
    (ptr-write! (ptr-offset p -2147483649) value)))

(define (load-scaled-positive [p : (Ptr i64)])
  (:export-symbol "gep_load_scaled_positive") : i64
  (unsafe
    (ptr-read (ptr-offset p 268435456))))

(define (store-scaled-positive [p : (MutPtr i64)] [value : i64])
  (:export-symbol "gep_store_scaled_positive") : unit
  (unsafe
    (ptr-write! (ptr-offset p 268435456) value)))

(define (load-scaled-negative [p : (Ptr i64)])
  (:export-symbol "gep_load_scaled_negative") : i64
  (unsafe
    (ptr-read (ptr-offset p -268435457))))

(define (store-scaled-negative [p : (MutPtr i64)] [value : i64])
  (:export-symbol "gep_store_scaled_negative") : unit
  (unsafe
    (ptr-write! (ptr-offset p -268435457) value)))

(define (load-maximum [p : (Ptr u8)])
  (:export-symbol "gep_load_maximum") : u8
  (unsafe
    (ptr-read (ptr-offset p 9223372036854775807))))

(define (store-maximum [p : (MutPtr u8)] [value : u8])
  (:export-symbol "gep_store_maximum") : unit
  (unsafe
    (ptr-write! (ptr-offset p 9223372036854775807) value)))

(define (load-minimum [p : (Ptr u8)])
  (:export-symbol "gep_load_minimum") : u8
  (unsafe
    (ptr-read (ptr-offset p -9223372036854775808))))

(define (store-minimum [p : (MutPtr u8)] [value : u8])
  (:export-symbol "gep_store_minimum") : unit
  (unsafe
    (ptr-write! (ptr-offset p -9223372036854775808) value)))

(define (wide-address [p : (Ptr u8)])
  (:export-symbol "gep_wide_address") : u64
  (unsafe
    (ptr->int (ptr-offset p 2147483648))))

(define (wide-second-load [p : (Ptr u8)])
  (:export-symbol "gep_wide_second_load") : i64
  (unsafe
    (+
      (cast (ptr-read p) : i64)
      (cast (ptr-read (ptr-offset p 2147483648)) : i64))))

(define (wide-alu [p : (Ptr i64)])
  (:export-symbol "gep_wide_alu") : i64
  (unsafe
    (+ (ptr-read (ptr-offset p 268435456)) 5)))

(define (wide-compare [p : (Ptr i64)])
  (:export-symbol "gep_wide_compare") : i64
  (unsafe
    (if (= (ptr-read (ptr-offset p 268435456)) 37)
      1
      0)))

(define (wide-branch [p : (Ptr i64)])
  (:export-symbol "gep_wide_branch") : i64
  (unsafe
    (if (= (ptr-read (ptr-offset p 268435456)) 37)
      (ptr-read p)
      0)))

(define (main) : i64
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 16)]
    [address : u64
      (unsafe
        (ptr->int (__tl_array-data bytes)))]
    [passed : i64 0]
    (let
      [base : (MutPtr u8)
        (unsafe
          (int->ptr
            (- address (* (cast 2147483647 : u64) (cast 1 : u64)))
            : (MutPtr u8)))]
      (store-positive-boundary base (cast 37 : u8))
      (when
        (=
          (cast
            (load-positive-boundary
              (unsafe
                (ptr-cast base : (Ptr u8))))
            : i64)
          37)
        (+= passed 1)))
    (let
      [base : (MutPtr u8)
        (unsafe
          (int->ptr
            (- address (* (cast 2147483648 : u64) (cast 1 : u64)))
            : (MutPtr u8)))]
      (store-positive-wide base (cast 37 : u8))
      (when
        (=
          (cast
            (load-positive-wide
              (unsafe
                (ptr-cast base : (Ptr u8))))
            : i64)
          37)
        (+= passed 1)))
    (let
      [base : (MutPtr u8)
        (unsafe
          (int->ptr
            (- address (* (cast -2147483648 : u64) (cast 1 : u64)))
            : (MutPtr u8)))]
      (store-negative-boundary base (cast 37 : u8))
      (when
        (=
          (cast
            (load-negative-boundary
              (unsafe
                (ptr-cast base : (Ptr u8))))
            : i64)
          37)
        (+= passed 1)))
    (let
      [base : (MutPtr u8)
        (unsafe
          (int->ptr
            (- address (* (cast -2147483649 : u64) (cast 1 : u64)))
            : (MutPtr u8)))]
      (store-negative-wide base (cast 37 : u8))
      (when
        (=
          (cast
            (load-negative-wide
              (unsafe
                (ptr-cast base : (Ptr u8))))
            : i64)
          37)
        (+= passed 1)))
    (let
      [base : (MutPtr i64)
        (unsafe
          (int->ptr
            (- address (* (cast 268435456 : u64) (cast 8 : u64)))
            : (MutPtr i64)))]
      (store-scaled-positive base 37)
      (when
        (=
          (load-scaled-positive
            (unsafe
              (ptr-cast base : (Ptr i64))))
          37)
        (+= passed 1)))
    (let
      [base : (MutPtr i64)
        (unsafe
          (int->ptr
            (- address (* (cast -268435457 : u64) (cast 8 : u64)))
            : (MutPtr i64)))]
      (store-scaled-negative base 37)
      (when
        (=
          (load-scaled-negative
            (unsafe
              (ptr-cast base : (Ptr i64))))
          37)
        (+= passed 1)))
    (let
      [base : (MutPtr u8)
        (unsafe
          (int->ptr
            (- address (* (cast 9223372036854775807 : u64) (cast 1 : u64)))
            : (MutPtr u8)))]
      (store-maximum base (cast 37 : u8))
      (when
        (=
          (cast
            (load-maximum
              (unsafe
                (ptr-cast base : (Ptr u8))))
            : i64)
          37)
        (+= passed 1)))
    (let
      [base : (MutPtr u8)
        (unsafe
          (int->ptr
            (- address (* (cast -9223372036854775808 : u64) (cast 1 : u64)))
            : (MutPtr u8)))]
      (store-minimum base (cast 37 : u8))
      (when
        (=
          (cast
            (load-minimum
              (unsafe
                (ptr-cast base : (Ptr u8))))
            : i64)
          37)
        (+= passed 1)))
    (let
      [base : (Ptr u8)
        (unsafe
          (int->ptr (- address (cast 2147483648 : u64)) : (Ptr u8)))]
      (when (= (wide-address base) address) (+= passed 1)))
    (let
      [base : (Ptr i64)
        (unsafe
          (int->ptr (- address (cast 2147483648 : u64)) : (Ptr i64)))]
      (when (= (wide-alu base) 42) (+= passed 1))
      (when (= (wide-compare base) 1) (+= passed 1)))
    (if (= passed 11)
      42
      0)))