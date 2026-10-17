;; A diverging arm has no normal result, so it neither loses nor needs an
;; obligated owner. The arm's contextual coercion to the join type is a use
;; adjustment; it must not hide divergence from the obligation checker, whether
;; the arm calls a stdlib or a local `never` function, with or without `return`.
(import stdlib.io)

(define closes : i64
  0)

(define (close-fd [_fd : i64]) : unit
  (set! closes (+ closes 1)))

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(define (fail) : never
  (io.panic "no normal value"))

(define (returned-local [flag : bool]) : Handle
  (let
    [h : Handle (Handle 1)]
    (return
      (if flag
        h
        (fail)))))

(define (tail-stdlib [flag : bool]) : Handle
  (let
    [h : Handle (Handle 2)]
    (if flag
      h
      (io.panic "no normal value"))))

(define (tail-local-first [flag : bool]) : Handle
  (let
    [h : Handle (Handle 3)]
    (if flag
      (fail)
      h)))

(define (main) : i64
  (begin
    (with ([a (returned-local true) cleanup-handle]) unit)
    (with ([b (tail-stdlib true) cleanup-handle]) unit)
    (with ([c (tail-local-first false) cleanup-handle]) unit)
    (+ closes 39)))