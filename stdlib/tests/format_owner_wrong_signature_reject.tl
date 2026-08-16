(module format_owner_wrong_signature_reject)

(import stdlib.format)

(defstruct WrongDisplay
  (value i64))

;; Owner hooks must borrow the displayed value.
(define (to-string [_value : WrongDisplay]) : String
  "wrong")

(define (main) : i64
  (begin
    (format.format "{}" (WrongDisplay 1))
    42))