;; A reference type passed as a macro `Expr` unquotes into a type position
;; (#8581): a `for` item annotated `(& a T)`, and a user macro forwarding
;; `(& a T)` and `(&mut a T)` into a `let` annotation.
(defmacro (read-as [ty : Expr] [v : Expr]) : Expr
  `(let
    [tmp : ,ty ,v]
    (deref tmp)))

(defmacro (bump-as [ty : Expr] [v : Expr]) : Expr
  `(let
    [tmp : ,ty ,v]
    (set! (deref tmp) (+ (deref tmp) 1))))

(define (sum [arr : (& a (Array i64 4))]) : i64
  (let
    [total : i64 0]
    (for [x : (& a i64) arr] (set! total (+ total (deref x))))
    total))

(define (read [x : (& a i64)]) : i64
  (read-as (& a i64) x))

(define (inc [x : (&mut a i64)]) : unit
  (bump-as (&mut a i64) x))

(define (main) : i64
  (let
    [arr : (Array i64 4) (array 1 2 3 34)]
    [n : i64 4]
    (inc (&mut n))
    (+ (sum (& arr)) (- (read (& n)) 3))))