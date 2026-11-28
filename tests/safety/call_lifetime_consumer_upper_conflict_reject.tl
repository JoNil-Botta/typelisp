(defstruct Consumer
  (:lifetimes t)
  (apply (-> (& t i64) i64)))

(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(define (take
  [consumer : (Consumer t)]
  [x : (& t i64)]
  [y : (& t i64)]
  [target : (&mut r (RefBox t))]) : i64
  (+ (consumer.apply target.value) (+ (consumer.apply x) (consumer.apply y))))

(define (probe [x : (& a i64)] [y : (& b i64)] [target : (&mut r (RefBox b))]) : i64
  (let
    [local : i64 7]
    [callback : (-> (& local i64) i64)
      (lambda ([v : (& local i64)]) : i64
        (deref v))]
    [consumer : (Consumer local) (Consumer callback)]
    (take consumer x y target)))

(define (main) : i64
  0)