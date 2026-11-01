;; A diverging initializer is still checked as the exit it is: a `return`
;; initializer leaves the scope of an earlier `let` owner, whose cleanup
;; obligation must be discharged first.
(define (close-fd [_fd : i64]) : unit
  unit)

(defstruct Handle
  (:cleanup cleanup-handle)
  (fd i64 (:cleanup close-fd)))

(define (early [x : i64]) : i64
  (let
    [h : Handle (Handle x)]
    [result : i64 (return x)]
    (cleanup-handle h)
    result))

(define (main) : i64
  (early 42))