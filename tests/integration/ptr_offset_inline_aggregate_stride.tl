;; refs #2606: ptr-offset over an inline aggregate pointee must stride by the
;; aggregate byte size, not by the backend's pointer-sized aggregate handle.
(defstruct PtrOffsetTriple
  (a i64)
  (b i64)
  (c i64))

(define (main) : i64
  (let
    [items : (Array PtrOffsetTriple) (make-array PtrOffsetTriple 2)]
    (begin
      (array-set! items 0 (PtrOffsetTriple 1 2 3))
      (array-set! items 1 (PtrOffsetTriple 13 17 19))
      (let
        [second : PtrOffsetTriple
          (unsafe
            (ptr-read
              (ptr-offset
                (ptr-cast (array-data items) : (Ptr PtrOffsetTriple))
                1)))]
        [value : i64 (struct-get second b)]
        (if (= value 17)
          42
          value)))))