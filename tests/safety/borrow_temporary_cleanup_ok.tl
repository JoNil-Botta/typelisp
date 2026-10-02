;: A cleanup-owning temporary borrowed as a call argument is cleaned right
;: after the call returns, including after a mutable borrow changed it.
(define closed : i64
  0)

(define (close-fd [fd : i64]) : unit
  (set! closed (+ closed fd)))

(defstruct FileHandle
  (:cleanup close-file-handle)
  (fd i64 (:cleanup close-fd)))

(defenum Slot
  (:cleanup close-slot)
  (Open i64 (:cleanup close-fd))
  (Free))

(define (read-fd [h : (& FileHandle)]) : i64
  h.fd)

(define (bump-fd! [h : (&mut FileHandle)]) : i64
  (begin
    (set! h.fd (+ h.fd 1))
    h.fd))

(define (slot-fd [s : (& Slot)]) : i64
  (match s
    [(Slot.Open fd) fd]
    [(Slot.Free) 0]))

(define (main) : i64
  (let
    [a : i64 (read-fd (& (FileHandle 10)))]
    [after-a : i64 closed]
    [b : i64 (bump-fd! (&mut (FileHandle 20)))]
    [after-b : i64 closed]
    [c : i64 (slot-fd (& (Slot.Open 5)))]
    (if (and
      (= a 10)
      (= after-a 10)
      (= b 21)
      (= after-b 31)
      (= c 5)
      (= closed 36))
      42
      1)))