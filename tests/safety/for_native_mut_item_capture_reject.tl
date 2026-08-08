(define (capture-native-mut-item [items : (&mut source (Array i64 2))]) : i64
  (let
    [saved : (-> i64)
      (lambda () : i64
        0)]
    (begin
      (for
        [item items]
        (set!
          saved
          (lambda () : i64
            (deref item))))
      (saved))))

(define (main) : i64
  0)