(import dispatch_value_provider as provider)
(import dispatch_value_provider.by-value as selected-value)
(import dispatch_value_provider.by-call as selected-call)

(define (apply-one [f : (-> i64 i64)] [x : i64]) : i64
  (f x))

(define (main) : i64
  (let
    [f : (-> i64 i64) selected-value]
    (if (and
      (= (provider.by-call 40) 42)
      (= (selected-call 40) 42)
      (= (apply-one provider.by-value 41) 42)
      (= (apply-one f 41) 42)
      (= (provider.callback 41) 42)
      (= (provider.value-auto 41) 42)
      (= (provider.call-auto 40) 42))
      42
      1)))