;; Explicit C pointer-plus-length interop for a fixed-array owner.  The
;; borrowed Slice type stays internal to TypeLisp; the FFI boundary receives
;; only an unsafe raw pointer and an explicit scalar length.
(extern (cabi-slice-ptr-len-sum [data : (Ptr i64)] [len : i64]) : i64 (:symbol "tl_cabi_slice_ptr_len_sum"))
(extern (cabi-slice-ptr-len-add-first-and-sum
  [data : (MutPtr i64)]
  [len : i64]
  [delta : i64]) : i64 (:symbol "tl_cabi_slice_ptr_len_add_first_and_sum"))

(define (main) : i64
  (let
    [items : (Array i64 3) (array 10 20 3)]
    [mut-data : (MutPtr i64)
      (unsafe
        (__tl_array-data items))]
    [read-data : (Ptr i64)
      (unsafe
        (ptr-cast mut-data : (Ptr i64)))]
    [before : i64 (cabi-slice-ptr-len-sum read-data 3)]
    [after : i64 (cabi-slice-ptr-len-add-first-and-sum mut-data 3 9)]
    (unless (= before 33) (return 1))
    (unless (= after 42) (return 2))
    (unless (= (array-ref items 0) 19) (return 3))
    42))