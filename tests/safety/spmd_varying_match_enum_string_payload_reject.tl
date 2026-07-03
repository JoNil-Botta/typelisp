;: SPEC SPMD contract: varying enum match payload bindings must stay in supported lane value types.
(import stdlib.array)

(defenum Choice
  (Named String)
  (Code i64))

(define (main [items : (Array Choice)] [out : (Array i64)] [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (array-set!
      out
      i
      (match (array-ref items i)
        [(Named name) 1]
        [(Code value) value]))))