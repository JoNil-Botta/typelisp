;: A live mutable borrow of lifetime-tagged iterator state protects its fields.
(defstruct Iter
  (:lifetimes source)
  (slots (& source (Array i64)))
  (len i64)
  (index i64))

(defenum Next
  (Done)
  (Item i64))

(define (next [iter : (&mut iter (Iter source))]) : Next
  (let
    [index : i64 (struct-get iter index)]
    (if (>= index (struct-get iter len))
      (Done)
      (begin
        (set! (struct-get iter index) (+ index 1))
        (Item index)))))

(define (hold [iter : (&mut iter (Iter source))]) : (&mut iter (Iter source))
  iter)

(define (main) : unit
  (let
    [items : (Array i64) (make-array i64 1)]
    [iter : (Iter items) (Iter (& items) 1 0)]
    [borrowed : (&mut iter (Iter items)) (hold (&mut iter))]
    (begin
      (set! (struct-get iter index) 1)
      (next borrowed)
      unit)))