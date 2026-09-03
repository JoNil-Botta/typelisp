;; ProcessStringList storage derives its live count from the backing array.
;; Safe source must not be able to restore a separately trusted count.
(import stdlib.process)

(define (main) : i64
  (let
    [slots : (__tl_dyn-array String) (__tl_make-array String 0)]
    [args : process.ProcessStringList
      (process.ProcessStringList slots 9223372036854775807)]
    (process.args-count args)))