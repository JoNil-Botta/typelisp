;; #9770 control: a closure made and called inside an arena that captures a
;; reference. Its inferred local and its function-type annotation both take the
;; closure's environment type, so the arena tag on the function type does not
;; hide the closure from its binding (E0200 regression).
(define (main) : i64
  (let
    [n : i64 20]
    [r : (& n i64) (& n)]
    (with-arena
      scratch
      (let
        [inferred
          (lambda () : i64
            (deref r))]
        [annotated : (-> i64)
          (lambda () : i64
            (deref r))]
        (+ (inferred) (annotated) 2)))))