(module format_owner_beta)

(defstruct Token
  (value i64))

(define (to-string [value : (& value Token)]) : String
  (if (= value.value 2)
    "beta"
    "beta-other"))