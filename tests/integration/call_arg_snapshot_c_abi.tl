;; #8433: an extern call evaluates its arguments left to right too, so C
;; receives the value an argument had when it was evaluated, even when a later
;; argument assigns the variable it read. Linked against the C baseline of
;; c_abi_slice_ptr_len. Exits 42, or the number of the first failed check.
(extern (slice-sum [data : (Ptr i64)] [len : i64]) : i64 (:symbol "tl_cabi_slice_ptr_len_sum"))
(extern (add-first-and-sum [data : (MutPtr i64)] [len : i64] [delta : i64]) : i64 (:symbol "tl_cabi_slice_ptr_len_add_first_and_sum"))

;; The pointer argument selects which owner C sums.
(define (pointer-argument) : bool
  (let
    [small : (Array i64 2) (array 1 2)]
    [large : (Array i64 2) (array 10 20)]
    [data : (Ptr i64)
      (unsafe
        (ptr-cast (__tl_array-data small) : (Ptr i64)))]
    [other : (Ptr i64)
      (unsafe
        (ptr-cast (__tl_array-data large) : (Ptr i64)))]
    (and
      (=
        (slice-sum
          data
          (begin
            (set! data other)
            2))
        3)
      (= (slice-sum data 2) 30))))

;; The length argument decides how many elements C sums, and C writes the
;; first element through the pointer.
(define (integer-argument) : bool
  (let
    [items : (Array i64 3) (array 1 2 3)]
    [data : (MutPtr i64)
      (unsafe
        (__tl_array-data items))]
    [len : i64 2]
    (and
      (=
        (add-first-and-sum
          data
          len
          (begin
            (set! len 3)
            10))
        13)
      (= len 3)
      (= (array-ref items 0) 11))))

(define (main) : i64
  (cond [(not (pointer-argument)) 1] [(not (integer-argument)) 2] [else 42]))