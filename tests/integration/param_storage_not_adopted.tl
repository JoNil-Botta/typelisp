;; A by-value aggregate parameter arrives as the address of its caller's
;; argument, so a `let` that moves it must copy it rather than take over that
;; storage. Here the argument is a bitwise `ptr-read` copy forwarded through
;; `mid`: `leaf` walking its own cursor once rewrote `top`'s `p` in place.
(defstruct P
  (len i64)
  (data (__tl_dyn-array i64)))

(define (leaf [p : P] [n : i64]) : i64
  (let
    [cursor : P p]
    [i : i64 0]
    (while (< i n)
      (set! cursor.len (- cursor.len 1))
      (set! i (+ i 1)))
    cursor.len))

(define (mid [p : P] [n : i64]) : i64
  (leaf p n))

(define (top [p : P]) : i64
  (let
    [walked : i64
      (mid
        (unsafe
          (ptr-read (ptr-addr-of p)))
        5)]
    (if (and (= walked 0) (= p.len 5))
      42
      1)))

(define (main) : i64
  (let
    [p : P (P 5 (__tl_make-array i64 1))]
    (top
      (unsafe
        (ptr-read (ptr-addr-of p))))))