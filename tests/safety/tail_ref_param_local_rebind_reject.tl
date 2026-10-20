;; A shorter frame-local borrow cannot replace a reference parameter before
;; forwarding it. This must be rejected before tail-call selection (#9183).
(defstruct Pair
  (x i64)
  (y i64))

(define (read-ref [r : (& i64)]) : i64
  (deref r))

(define (rebind [r : (& i64)]) : i64
  (let
    [local : Pair (Pair 42 0)]
    (set! r (& local.x))
    (read-ref r)))

(define (main) : i64
  (let
    [x : i64 0]
    (rebind (& x))))