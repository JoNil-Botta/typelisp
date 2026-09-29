;; An inner break must preserve an owner bound at loop depth 63.
(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(defmacro (at-depth-63 [body : Expr]) : Expr
  (let
    [out : Expr body]
    [i : i64 0]
    (begin
      (while (< i 63)
        (begin
          (set!
            out
            `(while true
              (begin
                ,out
                (break))))
          (set! i (+ i 1))))
      out)))

(define (main) : i64
  (begin
    (with
      ([root (Handle 1) cleanup-handle])
      (at-depth-63
        (let
          [h : Handle (Handle 2)]
          (begin
            (while true
              (break))
            (cleanup-handle h)))))
    (if (= closes 2)
      42
      1)))