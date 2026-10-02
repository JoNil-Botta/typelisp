;; Scalar `for` over each source kind: an owned range counted in place,
;; borrowed fixed arrays, Slices and `__tl_dyn-array`s, and borrowed slots/len
;; structs walked by index (unless their module defines the protocol), alone
;; and zipped. `main` returns 42 only when every loop visits the expected items.
(import stdlib.iterator)
(import stdlib.iterator as it)
(import stdlib.iterator.range)
(import stdlib.string)
(import for_slots_protocol_provider as rings)
(import for_range_provider as ranges)

(defstruct Seq
  (slots (__tl_dyn-array i64))
  (len i64))

(defstruct Names
  (slots (__tl_dyn-array String))
  (len i64))

(define bound-evaluations : i64
  0)

(define (counted-bound [value : i64]) : i64
  (begin
    (set! bound-evaluations (+ bound-evaluations 1))
    value))

(define (text-length [text : (& text str)]) : i64
  (string.string-length text))

(define (range-total) : i64
  (let
    [total : i64 0]
    [visits : i64 0]
    (begin
      ;; Each bound is evaluated once; `continue` still advances the index.
      (for [index (it.range (counted-bound 0) (counted-bound 6))]
        (set! visits (+ visits 1))
        (when (= index 1) (continue))
        (when (= index 4) (break))
        (set! total (+ total index)))
      ;; 0 + 2 + 3, five visits
      (for [index (iterator.range 7 7)]
        (set! total (+ total 1000)))
      (for [index (iterator.range 9 3)]
        (set! total (+ total 1000)))
      (for [index : i64 (iterator.range 10 12)]
        (set! total (+ total index)))
      (for [index (range 100 102)]
        (set! total (+ total index)))
      ;; nested loops reuse the same item name
      (for [index (iterator.range 0 2)]
        (for [index (iterator.range 0 3)]
          (set! total (+ total index))))
      ;; 5 + 21 + 201 + 2 * 3 = 233
      (if (and (= visits 5) (= bound-evaluations 2))
        total
        -1))))

(define (range-value-total) : i64
  (let
    [total : i64 0]
    [kept : it.I64Range (it.range-inclusive 3 5)]
    (begin
      ;; Another module's `range` runs: it builds the inclusive 1..=3.
      (for [index (ranges.range 1 3)]
        (+= total index))
      ;; A range-valued local and inclusive calls count through their fields.
      (for [index kept]
        (+= total index))
      (for [index (it.range-inclusive 4 4)]
        (+= total index))
      (for [index (it.range-inclusive 5 4)]
        (+= total 1000))
      ;; An inclusive range ending at the largest i64 stops there.
      (for [index (it.range-inclusive 9223372036854775806 9223372036854775807)]
        (+= total 1))
      ;; 6 + 12 + 4 + 2
      total)))

(define (dyn-array-total) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [total : i64 0]
    (begin
      (set! (array-ref values 0) 1)
      (set! (array-ref values 1) 2)
      (set! (array-ref values 2) 3)
      (for [value (&mut values)]
        (set! (deref value) (* (deref value) 10)))
      (for [value (& values)]
        (set! total (+ total (deref value))))
      total)))

(define (sum-dyn-array [values : (& values (__tl_dyn-array i64))]) : i64
  (let
    [total : i64 0]
    (begin
      (for [value values]
        (set! total (+ total (deref value))))
      total)))

(define (slots-total) : i64
  (let
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 8)]
    [name-slots : (__tl_dyn-array String) (__tl_make-array String 4)]
    (begin
      (set! (array-ref slots 0) 5)
      (set! (array-ref slots 1) 6)
      ;; past `len`: never visited
      (set! (array-ref slots 2) 1000)
      (set! (array-ref name-slots 0) "ab")
      (set! (array-ref name-slots 1) "cde")
      (let
        [seq : Seq (Seq slots 2)]
        [names : Names (Names name-slots 2)]
        [total : i64 0]
        (begin
          (for [item (&mut seq)]
            (set! (deref item) (+ (deref item) 1)))
          (for [item (& seq)]
            (set! total (+ total (deref item))))
          ;; String items are borrowed in place, never cloned.
          (for [name (& names)]
            (set! total (+ total (text-length name))))
          ;; 6 + 7 + 2 + 3
          total)))))

(define (protocol-first) : i64
  (let
    [ring-slots : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    (begin
      (set! (array-ref ring-slots 0) 1)
      (set! (array-ref ring-slots 1) 2)
      (set! (array-ref ring-slots 2) 3)
      (let
        [ring : rings.Ring (rings.Ring ring-slots 3 1)]
        [order : i64 0]
        (begin
          ;; Ring's own iterator starts at slot 1 and wraps: 2, 3, 1.
          (for [item (& ring)]
            (set! order (+ (* order 10) (deref item))))
          order)))))

(define (zip-total) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [slots : (__tl_dyn-array i64) (__tl_make-array i64 4)]
    [fixed : (Array i64 4) (array 100 200 300 400)]
    [total : i64 0]
    (begin
      (set! (array-ref values 0) 1)
      (set! (array-ref values 1) 2)
      (set! (array-ref values 2) 3)
      (set! (array-ref slots 0) 10)
      (set! (array-ref slots 1) 20)
      (let
        [seq : Seq (Seq slots 2)]
        (begin
          ;; zip-shortest: `seq` has two items
          (for [left (& seq)]
            [middle (& values)]
            [right (& fixed)]
            [index (it.range 0 10)]
            (set!
              total
              (+
                total
                (+ (deref left) (+ (deref middle) (+ (deref right) index))))))
          ;; (10 + 1 + 100 + 0) + (20 + 2 + 200 + 1)
          (for [left (&mut seq)]
            [right (&mut values)]
            (set! (deref left) (+ (deref left) (deref right))))
          ;; seq is now 11, 22
          (+ total (+ (array-ref seq.slots 0) (array-ref seq.slots 1))))))))

(define (main) : i64
  (let
    [values : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    (begin
      (set! (array-ref values 0) 20)
      (set! (array-ref values 1) 22)
      (cond
        [(not (= (range-total) 233)) 1]
        [(not (= (dyn-array-total) 60)) 2]
        [(not (= (sum-dyn-array (& values)) 42)) 3]
        [(not (= (slots-total) 18)) 4]
        [(not (= (protocol-first) 231)) 5]
        [(not (= (zip-total) 367)) 6]
        [(not (= (range-value-total) 24)) 7]
        [else 42]))))