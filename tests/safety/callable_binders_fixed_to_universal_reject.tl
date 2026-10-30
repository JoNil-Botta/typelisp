(define (bad [value : (& keep i64)]) : i64
  (let
    [fixed
      (lambda ([argument : (& keep i64)]) : (& keep i64)
        argument)]
    [promoted : (-> (& independent i64) (& independent i64)) fixed]
    (deref (promoted value))))

(define (main) : i64
  0)