(defstruct Bag
  (items (Array i64 4))
  (n i64))

(define (write-item [p : (Ptr Bag)]) : unit
  (unsafe
    (set! (array-ref (deref p).items 1) 10)))

(define (main) : i64
  0)