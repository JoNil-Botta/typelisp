;: SPEC SPMD contract: varying enum match payload bindings must stay in supported lane value types.

(defenum Choice
  (Named String)
  (Code i64))

(define (main
  [items : (__tl_dyn-array Choice)]
  [out : (__tl_dyn-array i64)]
  [n : i64]) : unit
  (foreach
    ([i : i64 0 n])
    (set!
      (array-ref out i)
      (match (array-ref items i)
        [(Named name) 1]
        [(Code value) value]))))