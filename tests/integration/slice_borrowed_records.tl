;; A fixed array of lifetime-parameterized records that store shared references
;; can be borrowed as a native Slice (#8111): directly at a typed call, through
;; `slice-view`, empty and nested, with the stored text read through element
;; borrows. A shared Slice may shorten the element lifetime (`(Item text)` read
;; as `(Item items)`), as a shared borrow of one element may. Forming the views
;; copies no element and no text: each window takes 1000 views and measures
;; `profile.alloc-total` around them. With an argument it takes one
;; out-of-range view, which must trap before any view is formed.
(import stdlib.io)
(import stdlib.profile)
(import stdlib.string)

(defstruct Item
  (:lifetimes source)
  (text (& source str)))

(define views : i64
  1000)

(define (count [items : (& source (Slice (Item source)))]) : i64
  (array-length items))

(define (total-len [items : (& source (Slice (Item source)))]) : i64
  (let
    [index : i64 0]
    [sum : i64 0]
    (begin
      (while (< index (array-length items))
        (begin
          (set! sum (+ sum (string.string-length (array-ref items index).text)))
          (set! index (+ index 1))))
      sum)))

(define (first-text [items : (& source (Slice (Item source)))]) : (& source str)
  (array-ref items 0).text)

(define (count-refs [refs : (& refs (Slice (& refs str)))]) : i64
  (array-length refs))

;; 1000 whole-array and subrange views of one array, each read once.
(define (view-window [items : (& items (Array (Item items) 3))]) : bool
  (let
    [sum : i64 0]
    [index : i64 0]
    [before : i64 (profile.alloc-total)]
    (begin
      (while (< index views)
        (begin
          (set! sum (+ sum (total-len items)))
          (set! sum (+ sum (count (slice-view items 1 2))))
          (set! index (+ index 1))))
      (and (= (profile.alloc-total) before) (= sum 8000)))))

(define (shapes [a : (& a str)] [b : (& b str)]) : i64
  (let
    [items : (Array (Item a) 2) (array (Item a) (Item a))]
    [longer : (Array (Item b) 1) (array (Item b))]
    [refs : (Array (& a str) 2) (array a a)]
    [whole : (& items (Slice (Item a))) (slice-view items 0 2)]
    [empty : (& items (Slice (Item a))) (slice-view items 2 0)]
    [pairs : (Array (Tuple i64 (Item a)) 1) (array (tuple 7 (Item a)))]
    [nested : (Array (Array (Item a) 2) 1) (array items)]
    (cond
      [(not (= (count (& items)) 2)) 2]
      [(not (= (total-len (& items)) 4)) 3]
      [(not (= (string.string-length (first-text (& longer))) 3)) 4]
      [(not (= (count whole) 2)) 5]
      [(not (= (count empty) 0)) 6]
      [(not (= (count-refs (& refs)) 2)) 7]
      [(not (= (array-length (& pairs)) 1)) 8]
      [(not (= (count (& (array-ref nested 0))) 2)) 9]
      [else 0])))

(define (trap [a : (& a str)] [start : i64]) : i64
  (let
    [items : (Array (Item a) 2) (array (Item a) (Item a))]
    (count (slice-view items start 2))))

(define (main) : i64
  (let
    [a : String "ab"]
    [b : String "cde"]
    (if (> (io.arg-count) 1)
      (trap (& a) (string.>int (io.arg 1)))
      (let
        [items : (Array (Item a) 3)
          (array (Item (& a)) (Item (& a)) (Item (& a)))]
        [code : i64 (shapes (& a) (& b))]
        (cond
          [(not (= code 0)) code]
          [(not (view-window (& items))) 10]
          [else 42])))))