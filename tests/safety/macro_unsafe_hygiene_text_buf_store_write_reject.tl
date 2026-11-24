(import stdlib.text_buf_family)

(defstruct FakeStore
  (slots (__tl_dyn-array String)))

(define (main) : i64
  (let
    [store : (Box FakeStore) (box (FakeStore (__tl_make-array String 2)))]
    [idx : i64 0]
    [p : (MutPtr i64)
      (unsafe
        (ptr-addr-of idx))]
    (text_buf_family.text-buf-owned-store-write! store (ptr-read p) "ok")
    0))