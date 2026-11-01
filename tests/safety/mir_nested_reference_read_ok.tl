;; A reference behind a reference is read through the outer one's loan: reads
;; (`**r`) and a write through `&mut &mut` are checked by the ownership graph
;; (#8449 M5).
(define (read-both [r : (& outer (& inner i64))]) : i64
  (let
    [copied : (& inner i64) (deref r)]
    (+ (deref copied) (deref (deref r)))))

(define (read-through-mut [r : (& outer (&mut inner i64))]) : i64
  (deref (deref r)))

(define (write-through [r : (&mut outer (&mut inner i64))]) : unit
  (set! (deref (deref r)) 10))

(define (main) : i64
  42)