(defstruct Holder
  (value (& program i64)))

(define (keep [program : (& program i64)]) : (& program i64)
  program)

(define (main) : i64
  (let
    [local : i64 1]
    [holder (Holder (keep (& local)))]
    (deref holder.value)))