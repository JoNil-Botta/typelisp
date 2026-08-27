;; Direct comparison maps (#5679): the full predicate surface plus unsigned
;; integer and floating-point lanes. Bool stores use the masked vector planner;
;; this fixture pins that route as part of the contiguous-map operator surface.
(define (case-i64-predicates) : bool
  (let
    [n : i64 13]
    [left : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [right : (__tl_dyn-array i64) (__tl_make-array i64 n)]
    [eq-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [ne-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [lt-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [le-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [gt-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [ge-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref left i) (- i 6))
          (set! (array-ref right i) (- (% (* i 5) 11) 5))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (begin
          (set! (array-ref eq-out j) (= (array-ref left j) (array-ref right j)))
          (set!
            (array-ref ne-out j)
            (!= (array-ref left j) (array-ref right j)))
          (set! (array-ref lt-out j) (< (array-ref left j) (array-ref right j)))
          (set!
            (array-ref le-out j)
            (<= (array-ref left j) (array-ref right j)))
          (set! (array-ref gt-out j) (> (array-ref left j) (array-ref right j)))
          (set!
            (array-ref ge-out j)
            (>= (array-ref left j) (array-ref right j)))))
      (set! i 0)
      (while (and ok (< i n))
        (let
          [a : i64 (array-ref left i)]
          [b : i64 (array-ref right i)]
          (begin
            (unless
              (and
                (= (array-ref eq-out i) (= a b))
                (= (array-ref ne-out i) (!= a b))
                (= (array-ref lt-out i) (< a b))
                (= (array-ref le-out i) (<= a b))
                (= (array-ref gt-out i) (> a b))
                (= (array-ref ge-out i) (>= a b)))
              (set! ok false))
            (set! i (+ i 1)))))
      ok)))

(define (case-other-lanes) : bool
  (let
    [n : i64 19]
    [u-left : (__tl_dyn-array u32) (__tl_make-array u32 n)]
    [u-right : (__tl_dyn-array u32) (__tl_make-array u32 n)]
    [u-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [f32-left : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [f32-right : (__tl_dyn-array f32) (__tl_make-array f32 n)]
    [f32-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [f64-left : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [f64-right : (__tl_dyn-array f64) (__tl_make-array f64 n)]
    [f64-out : (__tl_dyn-array bool) (__tl_make-array bool n)]
    [i : i64 0]
    [ok : bool true]
    (begin
      (while (< i n)
        (begin
          (set! (array-ref u-left i) (cast (+ (* i 17) 9) : u32))
          (set! (array-ref u-right i) (cast (+ (* i 11) 31) : u32))
          (set! (array-ref f32-left i) (cast (- i 9) : f32))
          (set! (array-ref f32-right i) (cast (- (% (* i 3) 13) 6) : f32))
          (set! (array-ref f64-left i) (cast (- i 9) : f64))
          (set! (array-ref f64-right i) (cast (- (% (* i 5) 17) 8) : f64))
          (set! i (+ i 1))))
      (foreach
        ([j : i64 0 n])
        (set!
          (array-ref u-out j)
          (>= (array-ref u-left j) (array-ref u-right j))))
      (foreach
        ([j : i64 0 n])
        (set!
          (array-ref f32-out j)
          (<= (array-ref f32-left j) (array-ref f32-right j))))
      (foreach
        ([j : i64 0 n])
        (set!
          (array-ref f64-out j)
          (> (array-ref f64-left j) (array-ref f64-right j))))
      (set! i 0)
      (while (and ok (< i n))
        (begin
          (unless
            (and
              (=
                (array-ref u-out i)
                (>= (array-ref u-left i) (array-ref u-right i)))
              (=
                (array-ref f32-out i)
                (<= (array-ref f32-left i) (array-ref f32-right i)))
              (=
                (array-ref f64-out i)
                (> (array-ref f64-left i) (array-ref f64-right i))))
            (set! ok false))
          (set! i (+ i 1))))
      ok)))

(define (main) : i64
  (if (and (case-i64-predicates) (case-other-lanes))
    42
    1))