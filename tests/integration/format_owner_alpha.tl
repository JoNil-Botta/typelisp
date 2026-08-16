(module format_owner_alpha)

(defstruct Token
  (value i64))

(define (to-string [value : (& value Token)]) : String
  (if (= value.value 1)
    "alpha"
    "alpha-other"))