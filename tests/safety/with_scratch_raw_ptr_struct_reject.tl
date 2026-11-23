(defstruct PtrBox
  (p (Ptr i64)))

(define (main) : i64
  (let
    [x : i64 42]
    [pb : PtrBox
      (with-scratch
        (PtrBox
          (unsafe
            (ptr-cast (ptr-addr-of x) : (Ptr i64)))))]
    (unsafe
      (ptr-read (. pb p)))))