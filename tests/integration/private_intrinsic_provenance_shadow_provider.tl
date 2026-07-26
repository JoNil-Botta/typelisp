;; An imported module's own declaration still shadows a private intrinsic.
;; lint-allow: function-name-case -- intrinsic provenance fixture
(define (__tl_string_length [value : i64]) : i64
  (+ value 100))

(define (private-string-length-shadow [value : i64]) : i64
  (__tl_string_length value))