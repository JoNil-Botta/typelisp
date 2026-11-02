(defstruct Held
  (value (& program i64)))

;; The dummy local cannot turn another local's borrow into program storage.
(define (bad) : Held
  (let
    [program : i64 0]
    [local : i64 42]
    (Held (& local))))

(define (main) : i64
  0)