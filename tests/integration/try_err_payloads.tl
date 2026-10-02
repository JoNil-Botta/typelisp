;; The error exit of `(try expr)` across Err payload shapes: a struct of two
;; i64 fields, a struct of two i32 fields, an inline enum whose variants carry
;; a scalar or a struct, and a String. The enclosing families' Ok variants carry
;; one payload, none, or three. Inputs are offset by the argument count so
;; opt2 keeps every path.
(import stdlib.io)
(import stdlib.string)

(defstruct Pos
  (a i64)
  (b i64))

(defstruct Small
  (a i32)
  (b i32))

(defenum Kind
  (Lex i64)
  (Parse Pos))

(defenum RPos
  (Ok i64)
  (Err Pos))

(defenum RPos2
  (Ok bool)
  (Err Pos))

(defenum RSmall
  (Ok i64)
  (Err Small))

(defenum RSmall2
  (Ok)
  (Err Small))

(defenum RKind
  (Ok i64)
  (Err Kind))

(defenum RKind2
  (Ok i64 i64 i64)
  (Err Kind))

(defenum RStr
  (Ok i64)
  (Err String))

(defenum RStr2
  (Ok)
  (Err String))

(define (pos [x : i64]) : RPos
  (if (> x 0)
    (Ok x)
    (Err (Pos x (* 2 x)))))

(define (small [x : i64]) : RSmall
  (if (> x 0)
    (Ok x)
    (Err (Small (cast x : i32) 7))))

(define (kind [x : i64]) : RKind
  (cond [(> x 0) (Ok x)] [(= x 0) (Err (Lex 5))] [else (Err (Parse (Pos x 3)))]))

(define (str [x : i64]) : RStr
  (if (> x 0)
    (Ok x)
    (Err (string.int->string x))))

(define (p2 [x : i64]) : RPos2
  (Ok (> (try (pos x)) 1)))

(define (s2 [x : i64]) : RSmall2
  (let
    [_ : i64 (try (small x))]
    Ok))

(define (k2 [x : i64]) : RKind2
  (let
    [v : i64 (try (kind x))]
    (Ok v v v)))

(define (t2 [x : i64]) : RStr2
  (let
    [_ : i64 (try (str x))]
    Ok))

(define (kscore [r : RKind2]) : i64
  (match r
    [(Ok _ _ _) 1000]
    [(Err k)
      (match k
        [(Lex n) n]
        [(Parse p) (+ (* 10 p.a) p.b)])]))

(define (main) : i64
  (let
    [b : i64 (- (io.arg-count) 1)]
    (begin
      (unless
        (match (p2 (+ b 5))
          [(Ok v) v]
          [(Err _) false])
        (return 1))
      (unless
        (match (p2 (- b 5))
          [(Ok _) false]
          [(Err p) (and (= p.a -5) (= p.b -10))])
        (return 2))
      (unless
        (match (s2 (- b 3))
          [Ok false]
          [(Err s) (and (= s.a -3) (= s.b 7))])
        (return 3))
      (unless (= (kscore (k2 b)) 5) (return 4))
      (unless (= (kscore (k2 (- b 9))) -87) (return 5))
      (unless
        (match (k2 (+ b 9))
          [(Ok x y z) (= (+ x y z) 27)]
          [(Err _) false])
        (return 6))
      (unless
        (match (t2 (- b 42))
          [Ok false]
          [(Err m) (string.eq m "-42")])
        (return 7))
      42)))