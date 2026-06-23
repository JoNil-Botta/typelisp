;: Lifetime-tagged iterator state can be mutably borrowed and advanced in place.
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
      (let
        [value : i64 (array-ref (struct-get iter slots) index)]
        (begin
          (set! (struct-get iter index) (+ index 1))
          (Item value))))))

(define (value-or [result : Next] [fallback : i64]) : i64
  (match result
    [(Item value) value]
    [(Done) fallback]))

(define (done? [result : Next]) : bool
  (match result
    [(Done) true]
    [(Item _) false]))

(define (main) : i64
  (let
    [items : (Array i64) (make-array i64 2)]
    (begin
      (array-set! items 0 19)
      (array-set! items 1 23)
      (let
        [iter : (Iter items) (Iter (& items) 2 0)]
        [step1 : Next (next (&mut iter))]
        [step2 : Next (next (&mut iter))]
        [step3 : Next (next (&mut iter))]
        (if (and
          (= (value-or step1 0) 19)
          (= (value-or step2 0) 23)
          (done? step3)
          (= (struct-get iter index) 2))
          42
          1)))))