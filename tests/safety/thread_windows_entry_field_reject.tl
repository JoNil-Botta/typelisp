;; Storing the entry in an ordinary function-typed struct field is a type
;; mismatch (#7742). Check-only; never executed.
(import stdlib.thread)

(defstruct Holder
  (entry (-> i64 i64)))

(define (main) : i64
  (let
    [holder : Holder (Holder thread.thread-windows-entry)]
    0))