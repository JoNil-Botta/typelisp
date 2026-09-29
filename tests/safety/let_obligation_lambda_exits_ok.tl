;; An uncaptured lambda's return and try leave its scopes, not its caller's.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(defenum Outcome
  (Ok i64)
  (Err i64))

(define (uncaptured) : i64
  (let
    [h : Handle (Handle 1)]
    [f : (-> Outcome)
      (lambda () : Outcome
        (let
          [value : i64 (try (Outcome.Ok 42))]
          (return (Outcome.Ok value))))]
    (begin
      (cleanup-handle h)
      (match (f)
        [(Outcome.Ok value) value]
        [(Outcome.Err _) 1]))))

(define (lambda-local) : i64
  (let
    [h : Handle (Handle 2)]
    [f : (-> i64)
      (lambda () : i64
        (let
          [h : Handle (Handle 3)]
          (begin
            (cleanup-handle h)
            (return 42))))]
    (begin
      (cleanup-handle h)
      (f))))

(define (main) : i64
  (if (and (= (uncaptured) 42) (= (lambda-local) 42) (= closes 3))
    42
    1))