;; The address of an array element reads its index; the raw address accesses
;; nothing, and the unsafe read copies the element's bits.
(define (main) : i64
  (let
    [values : (Array i64 3) (array 1 42 3)]
    [index : i64 1]
    (unsafe
      (ptr-read (ptr-addr-of (array-ref values index))))))