;; A value allocated in an arena cannot be stored into a longer-lived binding,
;; so the store below is an escape (SPEC 3.9, 5.16; #9475).
(import stdlib.string)

(define (keep) : i64
  (let
    [kept : String (string.int->string 1)]
    (begin
      ; Must fail: `kept` outlives `scratch`.
      (with-arena scratch (set! kept (string.int->string 2)))
      (string.string-length (& kept)))))

(define (main) : i64
  (keep))