;; Capture the receiver and index before computing the RHS; check the final
;; element's bounds after it (SPEC 5.10). Scalar, aggregate, reference and
;; zero-size stores have one order.
(defstruct Triple
  (a i64)
  (b i64)
  (c i64))

(define (fixed-ok?) : bool
  (let
    [items : (Array i64 2) (array 10 20)]
    [index : i64 0]
    (begin
      (set!
        (array-ref items index)
        (begin
          (set! index 1)
          99))
      (and (= (array-ref items 0) 99) (= (array-ref items 1) 20) (= index 1)))))

(define (dynamic-ok?) : bool
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array 10 20 30)]
    [index : i64 0]
    (begin
      (set!
        (array-ref items index)
        (begin
          (set! index 1)
          99))
      (and (= (array-ref items 0) 99) (= (array-ref items 1) 20) (= index 1)))))

(define (write-slice! [items : (&mut items (Slice i64))]) : unit
  (let
    [index : i64 0]
    (set!
      (array-ref items index)
      (begin
        (set! index 1)
        99))))

(define (slice-ok?) : bool
  (let
    [items : (Array i64 2) (array 10 20)]
    (begin
      (write-slice! (&mut items))
      (and (= (array-ref items 0) 99) (= (array-ref items 1) 20)))))

(define (aggregate-ok?) : bool
  (let
    [items : (Array Triple 2) (array (Triple 1 2 3) (Triple 4 5 6))]
    [index : i64 0]
    [replacement : Triple (Triple 10 20 30)]
    (begin
      ;; Materialized aggregate RHS.
      (set!
        (array-ref items index)
        (begin
          (set! index 1)
          replacement))
      (unless
        (and (= (array-ref items 0).a 10) (= (array-ref items 1).a 4))
        (return false))
      (set! index 0)
      ;; Direct construction into the destination.
      (set!
        (array-ref items index)
        (Triple
          (begin
            (set! index 1)
            40)
          50
          60))
      (and
        (= (array-ref items 0).a 40)
        (= (array-ref items 0).c 60)
        (= (array-ref items 1).a 4)))))

(define (zero-size-ok?) : bool
  (let
    [items : (Array unit 2) (array unit unit)]
    [trace : i64 0]
    (begin
      (set!
        (array-ref
          items
          (begin
            (set! trace (+ (* trace 10) 1))
            0))
        (begin
          (set! trace (+ (* trace 10) 2))
          unit))
      (= trace 12))))

(define (main) : i64
  (cond
    [(not (fixed-ok?)) 1]
    [(not (dynamic-ok?)) 2]
    [(not (slice-ok?)) 3]
    [(not (aggregate-ok?)) 4]
    [(not (zero-size-ok?)) 5]
    [else 42]))