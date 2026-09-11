;; The raw runtime compatibility ABI remains sequentially consistent for both
;; supported widths. This fixture owns and pins the backing cells, then enters
;; unsafe only where it proves their pointer validity and concurrent-use policy.
(import stdlib.runtime)

(define (main) : i64
  (let
    [wide : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [narrow : (__tl_dyn-array i32) (__tl_make-array i32 1)]
    [wide-fetch : i64 0]
    [wide-cas : i64 0]
    [wide-final : i64 0]
    [narrow-fetch : i32 (cast 0 : i32)]
    [narrow-cas : i32 (cast 0 : i32)]
    [narrow-final : i32 (cast 0 : i32)]
    (unsafe
      (let
        [wide-ptr : (MutPtr i64) (__tl_array-data wide)]
        [narrow-ptr : (MutPtr i32) (__tl_array-data narrow)]
        (begin
          (runtime.atomic-i64-store-ptr! wide-ptr 10)
          (runtime.atomic-i64-add-ptr! wide-ptr 5)
          (set! wide-fetch (runtime.atomic-i64-fetch-add-ptr! wide-ptr 2))
          (set! wide-cas (runtime.atomic-i64-cas-ptr! wide-ptr 17 19))
          (set!
            wide-final
            (runtime.atomic-i64-load-ptr (ptr-cast wide-ptr : (Ptr i64))))
          (runtime.atomic-i32-store-ptr! narrow-ptr (cast 5 : i32))
          (runtime.atomic-i32-add-ptr! narrow-ptr (cast 6 : i32))
          (set!
            narrow-fetch
            (runtime.atomic-i32-fetch-add-ptr! narrow-ptr (cast 3 : i32)))
          (set!
            narrow-cas
            (runtime.atomic-i32-cas-ptr!
              narrow-ptr
              (cast 14 : i32)
              (cast 23 : i32)))
          (set!
            narrow-final
            (runtime.atomic-i32-load-ptr (ptr-cast narrow-ptr : (Ptr i32)))))))
    (if (and
      (= wide-fetch 15)
      (= wide-cas 17)
      (= wide-final 19)
      (= narrow-fetch (cast 11 : i32))
      (= narrow-cas (cast 14 : i32))
      (= narrow-final (cast 23 : i32)))
      42
      1)))