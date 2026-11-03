;; #8998: a variant that no argument constrains holds no reference, so its
;; enum's lifetime is free; one spelled like a parameter at the use site does not
;; read as that parameter's storage.
(defenum Text
  (:lifetimes cwd)
  (Missing)
  (Present (& cwd str)))

(defstruct Command
  (:lifetimes cwd)
  (id i64)
  (cwd (Text cwd)))

(defenum Maybe
  (:lifetimes x)
  (None)
  (Some (& x i64)))

(defstruct Pair
  (:lifetimes x)
  (left (Maybe x))
  (right (Maybe x)))

(define (none [cwd : (& next str)]) : (Text next)
  (Text.Missing))

(define (none-let [cwd : (& next str)]) : (Text next)
  (let
    [t : (Text next) (Text.Missing)]
    t))

(define (command [cwd : (& next str)]) : (Command next)
  (Command 1 (Text.Missing)))

(define (first [x : i64] [value : (Maybe a)]) : (Pair a)
  (Pair (Maybe.None) value))

(define (last [x : i64] [value : (Maybe a)]) : (Pair a)
  (Pair value (Maybe.None)))

(define (main) : i64
  0)