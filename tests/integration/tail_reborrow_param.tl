;; A tail call whose argument re-borrows a reference parameter, `(& l)` or
;; `(&mut l)` with `l` already a reference, passes that same reference, so it
;; keeps the frame-reusing jump exactly like passing `l` (#9137). A borrow of a
;; frame local, directly or through a local reference to it, still keeps the
;; call: the callee would read the frame the jump abandons.
(defstruct Lst
  (slots (__tl_dyn-array i64))
  (len i64))

(defstruct St
  (address i64))

(define (lst-len [v : (& v Lst)]) : i64
  v.len)

(define (lst-get [v : (& v Lst)] [i : i64]) : i64
  (array-ref v.slots i))

(define (inner [s : St] [l : (& Lst)] [k : i64]) : bool
  (if (>= k (lst-len l))
    false
    (if (= (lst-get l k) s.address)
      true
      (inner s l (+ k 1)))))

(define (wrap-direct [s : St] [l : (& Lst)]) : bool
  (inner s l 0))

(define (wrap-reborrow [s : St] [l : (& Lst)]) : bool
  (inner s (& l) 0))

;; A shared borrow of a mutable reference parameter.
(define (wrap-shared-of-mut [s : St] [l : (&mut Lst)]) : bool
  (inner s (& l) 0))

;; Counts `k` up to the length, writing through the reference on the way.
(define (bump [l : (&mut Lst)] [k : i64]) : i64
  (if (>= k l.len)
    k
    (begin
      (set! (array-ref l.slots k) (+ (array-ref l.slots k) 1))
      (bump l (+ k 1)))))

(define (wrap-mut-reborrow [l : (&mut Lst)]) : i64
  (bump (&mut l) 0))

;; A frame local, borrowed directly.
(define (wrap-local [s : St]) : bool
  (let
    [xs : Lst (Lst (__tl_make-array i64 2) 2)]
    (set! (array-ref xs.slots 1) 3)
    (inner s (& xs) 0)))

;; A local reference to a frame local, re-borrowed.
(define (wrap-local-ref [s : St]) : bool
  (let
    [xs : Lst (Lst (__tl_make-array i64 2) 2)]
    (set! (array-ref xs.slots 0) 3)
    (let
      [r : (& xs Lst) (& xs)]
      (inner s (& r) 0))))

(define (main) : i64
  (let
    [xs : Lst (Lst (__tl_make-array i64 4) 4)]
    [s : St (St 3)]
    (set! (array-ref xs.slots 2) 3)
    (if (and
      (wrap-direct s (& xs))
      (wrap-reborrow s (& xs))
      (wrap-shared-of-mut s (&mut xs))
      (wrap-local s)
      (wrap-local-ref s)
      (not (wrap-direct (St 9) (& xs))))
      (+ 38 (wrap-mut-reborrow (&mut xs)))
      1)))