; IAG-1: an aggregate global whose fields include another struct, so the inline
; cell holds a nested aggregate rather than a flat row of words.
(import stdlib.io)

(defstruct Point
  (x i64)
  (y i64))

(defstruct Frame
  (origin Point)
  (tag i64))

(define frame : Frame
  (Frame (Point 3 4) 5))

(define (install! [x : i64] [y : i64] [tag : i64]) : unit
  (set! frame (Frame (Point x y) tag)))

(define (weigh [f : (& Frame)]) : i64
  (+ f.origin.x (+ (* f.origin.y 10) (* f.tag 100))))

(define (report) : i64
  (+ (weigh (& frame)) (+ frame.origin.x (+ frame.origin.y frame.tag))))

(define (main) : i64
  (begin
    (io.print-format "{}\n" (report))
    (install! 6 7 8)
    (io.print-format "{}\n" (report))
    42))