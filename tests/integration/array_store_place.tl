;; A destination captures descriptor identity and index before the RHS, then
;; resolves its live backing buffer after RHS mutation. Nested projections keep
;; the same logical element, and rebinding a descriptor variable is different
;; from growing the captured descriptor.
(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(defstruct Bucket
  (parts (Array Triple 2)))

(defstruct Empty
  (value unit))

(defstruct WideBucket
  (leading i64)
  (parts (Array Triple 2))
  (trailing (Array i64 3)))

(define (grow?) : bool
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array 10 20)]
    [index : i64 0]
    [visits : i64 0]
    (begin
      (set!
        (array-ref
          items
          (begin
            (set! visits (+ visits 1))
            index))
        (begin
          (__tl_array-push! items 30)
          (set! index 1)
          99))
      (and
        (= (array-ref items 0) 99)
        (= (array-ref items 1) 20)
        (= (array-ref items 2) 30)
        (= (array-length items) 3)
        (= visits 1)))))

(define (grow-field?) : bool
  (let
    [items : (__tl_dyn-array Triple) (__tl_make-array (Triple 1 2 3))]
    (begin
      (set!
        (array-ref items 0).b
        (begin
          (__tl_array-push! items (Triple 4 5 6))
          99))
      (and
        (= (array-ref items 0).a 1)
        (= (array-ref items 0).b 99)
        (= (array-ref items 1).c 6)))))

(define (grow-nested-fixed?) : bool
  (let
    [items : (__tl_dyn-array Bucket)
      (__tl_make-array (Bucket (array (Triple 1 2 3) (Triple 4 5 6))))]
    (begin
      (set!
        (array-ref (array-ref items 0).parts 1).b
        (begin
          (__tl_array-push!
            items
            (Bucket (array (Triple 7 8 9) (Triple 10 11 12))))
          99))
      (and
        (= (array-ref (array-ref items 0).parts 1).b 99)
        (= (array-ref (array-ref items 0).parts 0).b 2)
        (= (array-ref (array-ref items 1).parts 1).b 11)))))

(define (rebind?) : bool
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array 10 20)]
    [replacement : (__tl_dyn-array i64) (__tl_make-array 30 40)]
    (begin
      (set!
        (array-ref items 0)
        (begin
          (set! items replacement)
          99))
      (and (= (array-ref items 0) 30) (= (array-ref items 1) 40)))))

(define (zero-size?) : bool
  (let
    [items : (__tl_dyn-array Empty) (__tl_make-array (Empty unit) (Empty unit))]
    [visits : i64 0]
    (begin
      (set!
        (array-ref
          items
          (begin
            (set! visits (+ visits 1))
            0))
        (begin
          (__tl_array-push! items (Empty unit))
          (set! visits (+ visits 1))
          (Empty unit)))
      (and (= visits 2) (= (array-length items) 3)))))

(define (wrapped-mixed? [choose : bool]) : bool
  (let
    [fixed : (Array Triple 2) (array (Triple 10 20 30) (Triple 40 50 60))]
    [items : (__tl_dyn-array Bucket)
      (__tl_make-array (Bucket (array (Triple 1 2 3) (Triple 4 5 6))))]
    [trace : i64 0]
    (begin
      (set!
        (array-ref
          (if (begin
            (set! trace (+ (* trace 10) 1))
            choose)
            (begin
              (set! trace (+ (* trace 10) 2))
              (array-ref items 0).parts)
            (begin
              (set! trace (+ (* trace 10) 3))
              fixed))
          (begin
            (set! trace (+ (* trace 10) 4))
            1))
        (begin
          (__tl_array-push!
            items
            (Bucket (array (Triple 7 8 9) (Triple 10 11 12))))
          (set! trace (+ (* trace 10) 5))
          (Triple 98 99 100)))
      (and
        (=
          trace
          (if choose
            1245
            1345))
        (=
          (array-ref fixed 1).b
          (if choose
            50
            99))
        (=
          (array-ref (array-ref items 0).parts 1).b
          (if choose
            99
            5))))))

(define (wrapped-different-layouts? [choose : bool]) : bool
  (let
    [left : (__tl_dyn-array Bucket)
      (__tl_make-array (Bucket (array (Triple 1 2 3) (Triple 4 5 6))))]
    [right : (__tl_dyn-array WideBucket)
      (__tl_make-array
        (WideBucket 0 (array (Triple 7 8 9) (Triple 10 11 12)) (array 0 0 0)))]
    (begin
      (set!
        (array-ref
          (if choose
            (array-ref left 0).parts
            (array-ref right 0).parts)
          1)
        (begin
          (__tl_array-push!
            left
            (Bucket (array (Triple 13 14 15) (Triple 16 17 18))))
          (__tl_array-push!
            right
            (WideBucket
              0
              (array (Triple 19 20 21) (Triple 22 23 24))
              (array 0 0 0)))
          (Triple 98 99 100)))
      (and
        (=
          (array-ref (array-ref left 0).parts 1).b
          (if choose
            99
            5))
        (=
          (array-ref (array-ref right 0).parts 1).b
          (if choose
            11
            99))))))

(define (let-storage?) : bool
  (let
    [items : (Array i64 2) (array 1 2)]
    [visits : i64 0]
    (begin
      (set!
        (array-ref
          (let
            [_n : i64
              (begin
                (set! visits (+ visits 1))
                0)]
            items)
          0)
        40)
      (set!
        (array-ref
          (let
            [copy : (Array i64 2) items]
            copy)
          0)
        99)
      (and (= (array-ref items 0) 40) (= visits 1)))))

(define (return-receiver? [choose : bool]) : bool
  (let
    [items : (Array i64 2) (array 1 2)]
    (begin
      (set!
        (array-ref
          (if choose
            (return true)
            items)
          0)
        40)
      (= (array-ref items 0) 40))))

(define (main) : i64
  (cond
    [(not (grow?)) 1]
    [(not (grow-field?)) 2]
    [(not (grow-nested-fixed?)) 3]
    [(not (rebind?)) 4]
    [(not (zero-size?)) 5]
    [(not (wrapped-mixed? true)) 6]
    [(not (wrapped-mixed? false)) 7]
    [(not (wrapped-different-layouts? true)) 8]
    [(not (wrapped-different-layouts? false)) 9]
    [(not (let-storage?)) 10]
    [(not (return-receiver? true)) 11]
    [(not (return-receiver? false)) 12]
    [else 42]))