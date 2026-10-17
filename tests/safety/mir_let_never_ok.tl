;; A diverging initializer contributes control flow, never initialized storage.
;; Later bindings and the body are typed, but their ownership effects are dead.
(import stdlib.io)

(define (consume [items : (__tl_dyn-array i64)]) : i64
  (array-length items))

(define (first [items : (__tl_dyn-array i64)]) : i64
  (let
    [answer : i64 (return (consume items))]
    (consume items)
    answer))

(define (middle [items : (__tl_dyn-array i64)]) : i64
  (let
    [answer : i64 (consume items)]
    [_dead : bool (io.panic "no result")]
    [again : i64 (consume items)]
    (+ answer again)))

(define (last [items : (__tl_dyn-array i64)]) : i64
  (let
    [answer : i64 (consume items)]
    [_dead : bool (return answer)]
    (consume items)))

(define (both-arms [items : (__tl_dyn-array i64)] [flag : bool]) : i64
  (let
    [answer : i64
      (if flag
        (return (consume items))
        (return (consume items)))]
    [again : i64 (consume items)]
    (+ answer again)))

(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(define (never-owner) : i64
  (let
    [resource : Handle (io.panic "no owner")]
    (cleanup-handle resource)
    0))

(define (inside-owner) : i64
  (with
    ([resource (Handle 1) cleanup-handle])
    (let
      [_answer : bool (io.panic "no result")]
      (cleanup-handle resource)
      (cleanup-handle resource)
      0)))

(define (return-through-owner) : i64
  (with
    ([resource (Handle 1) cleanup-handle])
    (let
      [answer : i64 (return 42)]
      (cleanup-handle resource)
      (cleanup-handle resource)
      answer)))

(define (main) : i64
  (if (and (= (return-through-owner) 42) (= closes 1))
    (+
      (first (__tl_make-array i64 10))
      (last (__tl_make-array i64 11))
      (both-arms (__tl_make-array i64 10) true)
      (both-arms (__tl_make-array i64 11) false))
    1))