;; #7725: even an unused checked result must reject null at every opt level.
(define (main) : i64
  (let
    [_checked : (CFunc non-null (-> i64 i64))
      (c-fn-check (ptr-null : (CFunc nullable (-> i64 i64))))]
    0))