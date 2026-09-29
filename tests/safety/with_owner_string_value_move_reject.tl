;; A `with` owner of any move-only type is moved through a consumed `if` value,
;; so its cleanup is not run on the moved value.
(import stdlib.string)

(define (close-name [_name : String]) : unit
  unit)

(define (keep [name : String]) : i64
  (string.string-length name))

(define (run [flag : bool]) : i64
  (with
    ([name (string.int->string 42) close-name])
    (begin
      (keep
        (if flag
          name
          "other"))
      0)))

(define (main) : i64
  (run true))