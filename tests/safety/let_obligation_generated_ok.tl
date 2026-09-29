;; The declared cleanup function of a generated type discharges an ordinary
;; `let` owner through the import alias that names it.
(import stdlib.sync)
(import (sync.mutex i64) as mutex_i64)
(import stdlib.vector)

(define (close-token [_value : i64]) : unit
  unit)

(defstruct CleanupToken
  (:cleanup cleanup-token)
  (value i64 (:cleanup close-token)))

(import (vector.vector CleanupToken) as tokens)

(define (read-locked [mutex : mutex_i64.Mutex]) : i64
  (let
    [guard : mutex_i64.Guard (mutex_i64.lock mutex)]
    (let
      [value : i64 (mutex_i64.get guard)]
      (begin
        (mutex_i64.unlock guard)
        value))))

(define (count-items) : i64
  (let
    [items : tokens.Vec (tokens.new)]
    (let
      [n : i64 (tokens.len (& items))]
      (begin
        (tokens.cleanup-vec items)
        n))))

(define (main) : i64
  (count-items))