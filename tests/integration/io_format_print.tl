(import stdlib.io)

(define (main) : i64
  (let
    ;; Referenced by generated call-site capture syntax.
    ;; lint-allow: unused-variable
    [name : String "Ada"]
    [score : i64 -7]
    ;; Referenced by generated call-site capture syntax.
    ;; lint-allow: unused-variable
    [answer : i64 42]
    (begin
      (io.print-format "{name}:{0}:{1}:{2}:{3}" score true 'x' 1.5)
      (io.println " {{done}}")
      (io.println "{answer}")
      0)))