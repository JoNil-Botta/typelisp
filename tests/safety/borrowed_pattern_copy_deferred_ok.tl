;: A scalar bound by value through a shared reference keeps the value it had at
;: the match (SPEC section 5.13), even when the arm changes the scrutinee before
;: reading the binding. Lowering reads such a binding from the scrutinee at each
;: use only when nothing that could write memory can run first; these arms
;: exercise both sides. A call can change a global scrutinee the borrow checker
;: does not track across calls.
(defenum Tok
  (Num i64)
  (Pair i64 bool)
  (Nil))

(define tok-cell : Tok
  (Tok.Num 1))

(define (set-cell! [value : i64]) : unit
  (set! tok-cell (Tok.Num value)))

(define (set-cell-value! [value : i64]) : i64
  (begin
    (set! tok-cell (Tok.Num value))
    3))

(define (peek [x : (& i64)]) : i64
  (deref x))

;; A call that writes the scrutinee runs before the read.
(define (read-after-call) : i64
  (begin
    (set-cell! 1)
    (match (& tok-cell)
      [(Tok.Num v)
        (begin
          (set-cell! 100)
          v)]
      [_ 0])))

;; The other operand of `+` writes the scrutinee.
(define (read-beside-call) : i64
  (begin
    (set-cell! 4)
    (match (& tok-cell)
      [(Tok.Num v) (+ v (set-cell-value! 200))]
      [_ 0])))

;; A loop reads the binding after the writes of earlier iterations.
(define (read-in-loop) : i64
  (let
    [total : i64 0]
    [i : i64 0]
    (begin
      (set-cell! 3)
      (match (& tok-cell)
        [(Tok.Num k)
          (begin
            (while (< i 3)
              (begin
                (set! total (+ total k))
                (set-cell! 100)
                (set! i (+ i 1))))
            total)]
        [_ 0]))))

;; One branch reads before any write, the other after one.
(define (read-in-branches [early : bool]) : i64
  (begin
    (set-cell! 8)
    (match (& tok-cell)
      [(Tok.Num k)
        (if early
          k
          (begin
            (set-cell! 50)
            k))]
      [_ 0])))

;; Reads before any write, through an auto-borrow, a lambda capture, an
;; explicit borrow, and both branches of an `if`.
(define (plain-reads) : i64
  (let
    [tok : Tok (Tok.Pair 10 false)]
    (match (& tok)
      [(Tok.Pair k flag)
        (let
          [f : (-> i64)
            (lambda () : i64
              (+ k 1))]
          (+
            (if flag
              100
              (peek k))
            (f)
            (peek (& k))
            (if (> k 3)
              (+ k 1)
              (- k 1))))]
      [_ 0])))

;; Nested borrowed matches, with an inner binding shadowing an outer one.
(define (nested [a : (& Tok)] [b : (& Tok)]) : i64
  (match a
    [(Tok.Num k)
      (match b
        [(Tok.Num k) (* k 2)]
        [(Tok.Pair j _) (+ k j)]
        [(Tok.Nil) k])]
    [_ -1]))

(define (main) : i64
  (let
    [two : Tok (Tok.Num 2)]
    [pair : Tok (Tok.Pair 5 true)]
    [nil : Tok (Tok.Nil)]
    (if (and
      (= (read-after-call) 1)
      (= (read-beside-call) 7)
      (= (read-in-loop) 9)
      (= (read-in-branches true) 8)
      (= (read-in-branches false) 8)
      (= (plain-reads) 42)
      (= (nested (& two) (& two)) 4)
      (= (nested (& two) (& pair)) 7)
      (= (nested (& two) (& nil)) 2)
      (= (nested (& nil) (& two)) -1))
      42
      1)))