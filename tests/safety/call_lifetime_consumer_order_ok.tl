(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(defstruct Consumer
  (:lifetimes t)
  (apply (-> (& t i64) i64)))

(define (take [consumer : (Consumer t)] [target : (&mut r (RefBox t))]) : i64
  (consumer.apply target.value))

(define (take-swapped [target : (&mut r (RefBox t))] [consumer : (Consumer t)]) : i64
  (consumer.apply target.value))

(define (take-mixed
  [first : (Consumer t)]
  [value : (& t i64)]
  [second : (Consumer t)]
  [target : (&mut r (RefBox t))]
  [last : (Consumer t)]) : i64
  (+
    (first.apply value)
    (+ (second.apply target.value) (last.apply target.value))))

(define (probe [target : (&mut r (RefBox a))]) : i64
  (let
    [local : i64 7]
    [callback : (-> (& local i64) i64)
      (lambda ([value : (& local i64)]) : i64
        (deref value))]
    [consumer : (Consumer local) (Consumer callback)]
    (+
      (take consumer target)
      (+
        (take-swapped target consumer)
        (take-mixed consumer target.value consumer target consumer)))))

(define (consume-two [consumer : (Consumer t)] [x : (& t i64)] [y : (& t i64)]) : i64
  (+ (consumer.apply x) (consumer.apply y)))

(define (independent-uppers [x : (& a i64)] [y : (& b i64)]) : i64
  (let
    [local : i64 7]
    [callback : (-> (& local i64) i64)
      (lambda ([v : (& local i64)]) : i64
        (deref v))]
    [consumer : (Consumer local) (Consumer callback)]
    (consume-two consumer x y)))

(define (main) : i64
  (let
    [value : i64 8]
    [holder (RefBox (& value))]
    (+ (probe (&mut holder)) (independent-uppers (& value) (& value)))))