(define (probe-fn [x : i64]) (:export-symbol "probe_sym") : unit unit)

(defmacro (all [first : bool] [rest : bool ...]) : bool first)
