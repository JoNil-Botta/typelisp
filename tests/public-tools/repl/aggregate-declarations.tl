(defstruct ReplPoint
  (x i64)
  (y i64))

(defenum ReplMaybe
  (ReplNone)
  (ReplSome i64))

(define repl-point : ReplPoint
  (ReplPoint 3 4))
(define repl-maybe : ReplMaybe
  (ReplSome 5))
(define repl-fixed : (Array i64 2)
  (array 6 7))