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

(defstruct WideHandle
  (:cleanup close-wide-handle)
  (fd i64 (:cleanup close-fd))
  (first i64)
  (second i64))

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

(define (bump-wide! [h : (&mut WideHandle)]) : i64
  (set! h.fd (+ h.fd h.first h.second))
  h.fd)

(define (read-pair [first : (& FileHandle)] [second : (& FileHandle)]) : i64
  ;; Both arguments stay alive until the call returns.
  (+ first.fd second.fd closed))

(define (main) : i64
  (let
    [a : i64 (read-fd (& (FileHandle 10)))]
    [after-a : i64 closed]
    [b : i64 (bump-fd! (&mut (FileHandle 20)))]
    [after-b : i64 closed]
    [c : i64 (slot-fd (& (Slot.Open 5)))]
    [after-c : i64 closed]
    [d : i64 (bump-wide! (&mut (WideHandle 7 2 3)))]
    [after-d : i64 closed]
    [pair : i64 (read-pair (& (FileHandle 4)) (& (FileHandle 6)))]
    (if (and
      (= a 10)
      (= after-a 10)
      (= b 21)
      (= after-b 31)
      (= c 5)
      (= after-c 36)
      (= d 12)
      (= after-d 48)
      (= pair 58)
      (= closed 58))
      42
      1)))