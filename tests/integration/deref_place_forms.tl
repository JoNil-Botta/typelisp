;; Every place form reached through `deref` writes and reads the referent
;; itself: whole and field stores through `&mut` to scalars, register-sized
;; and memory structs, enums and dynamic arrays (whose reference is the
;; header itself), element stores and pushes through `(deref r)`, through a
;; local reference, a field of a struct behind a reference and box contents.
;; Each check returns its own code when it fails, so a miscompile names the
;; form (#8449).
(defstruct Big
  (a i64)
  (b i64)
  (c i64))

(defstruct Small
  (a i32)
  (b i32))

(defstruct Bag
  (items (__tl_dyn-array i64))
  (n i64))

(defenum Pick
  (Left i64)
  (Right))

(define (set-scalar! [r : (&mut r i64)]) : unit
  (set! (deref r) 40))

(define (set-big! [r : (&mut r Big)]) : unit
  (set! (deref r) (Big 10 20 10)))

(define (set-big-field! [r : (&mut r Big)]) : unit
  (set! (deref r).b 38))

(define (set-small! [r : (&mut r Small)]) : unit
  (set! (deref r) (Small (cast 20 : i32) (cast 20 : i32))))

(define (set-small-field! [r : (&mut r Small)]) : unit
  (set! (deref r).b (cast 39 : i32)))

(define (set-pick! [r : (&mut r Pick)]) : unit
  (set! (deref r) (Pick.Left 40)))

(define (set-array! [r : (&mut r (__tl_dyn-array i64))]) : unit
  (set! (deref r) (__tl_make-array i64 40)))

(define (set-element! [r : (&mut r (__tl_dyn-array i64))]) : unit
  (set! (array-ref (deref r) 1) 40))

(define (push-deref! [r : (&mut r (__tl_dyn-array i64))]) : unit
  (let
    [i : i64 0]
    (while (< i 40)
      (__tl_array-push! (deref r) i)
      (set! i (+ i 1)))))

(define (read-deref [r : (& r (__tl_dyn-array i64))]) : i64
  (+ (array-length (deref r)) (array-ref (deref r) 1)))

(define (push-field! [r : (&mut r Bag)]) : unit
  (let
    [i : i64 0]
    (while (< i 40)
      (__tl_array-push! (deref r).items i)
      (set! i (+ i 1)))))

(define (set-field-array! [r : (&mut r Bag)]) : unit
  (set! (deref r).items (__tl_make-array i64 40)))

(define (push-boxed! [r : (&mut r (Box (__tl_dyn-array i64)))]) : unit
  (let
    [i : i64 0]
    (while (< i 40)
      (__tl_array-push! (deref (deref r)) i)
      (set! i (+ i 1)))))

(define (check-scalars) : i64
  (let
    [x : i64 1]
    [big : Big (Big 1 1 1)]
    [big2 : Big (Big 1 1 1)]
    [small : Small (Small (cast 1 : i32) (cast 1 : i32))]
    [small2 : Small (Small (cast 1 : i32) (cast 1 : i32))]
    [pick : Pick Pick.Right]
    (set-scalar! (&mut x))
    (set-big! (&mut big))
    (set-big-field! (&mut big2))
    (set-small! (&mut small))
    (set-small-field! (&mut small2))
    (set-pick! (&mut pick))
    (cond
      [(!= x 40) 1]
      [(!= (+ big.a big.b big.c) 40) 2]
      [(!= (+ big2.a big2.b big2.c) 40) 3]
      [(!= (+ (cast small.a : i64) (cast small.b : i64)) 40) 4]
      [(!= (+ (cast small2.a : i64) (cast small2.b : i64)) 40) 5]
      [(match pick
          [(Pick.Left v) (!= v 40)]
          [(Pick.Right) true])
        6]
      [else 0])))

(define (check-arrays) : i64
  (let
    [whole : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [element : (__tl_dyn-array i64) (__tl_make-array i64 2)]
    [pushed : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [read : (__tl_dyn-array i64) (__tl_make-array i64 3)]
    [bag : Bag (Bag (__tl_make-array i64 0) 0)]
    [bag2 : Bag (Bag (__tl_make-array i64 0) 0)]
    [boxed : (Box (__tl_dyn-array i64)) (box (__tl_make-array i64 0))]
    (set-array! (&mut whole))
    (set-element! (&mut element))
    (push-deref! (&mut pushed))
    (set! (array-ref read 1) 37)
    (push-field! (&mut bag))
    (set-field-array! (&mut bag2))
    (push-boxed! (&mut boxed))
    (cond
      [(!= (array-length whole) 40) 11]
      [(!= (array-ref element 1) 40) 12]
      [(!= (array-length pushed) 40) 13]
      [(!= (array-ref pushed 39) 39) 14]
      [(!= (read-deref (& read)) 40) 15]
      [(!= (array-length bag.items) 40) 16]
      [(!= (array-length bag2.items) 40) 17]
      [(!= (array-length (deref boxed)) 40) 18]
      [else 0])))

(define (check-locals) : i64
  (let
    [pushed : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    [whole : (__tl_dyn-array i64) (__tl_make-array i64 0)]
    (let
      [r : (&mut pushed (__tl_dyn-array i64)) (&mut pushed)]
      [i : i64 0]
      (while (< i 40)
        (__tl_array-push! (deref r) i)
        (set! i (+ i 1))))
    (let
      [w : (&mut whole (__tl_dyn-array i64)) (&mut whole)]
      (set! (deref w) (__tl_make-array i64 40)))
    (cond
      [(!= (array-length pushed) 40) 21]
      [(!= (array-length whole) 40) 22]
      [else 0])))

(define (main) : i64
  (let
    [scalars : i64 (check-scalars)]
    [arrays : i64 (check-arrays)]
    [locals : i64 (check-locals)]
    (cond
      [(!= scalars 0) scalars]
      [(!= arrays 0) arrays]
      [(!= locals 0) locals]
      [else 42])))