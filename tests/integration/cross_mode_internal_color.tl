;; A transport-free internal-call twin of c_abi_aggregate_color.tl. The
;; cross-mode corpus compares their exact native observations after the normal
;; integration gate has already built and validated both programs.
(import stdlib.io)

(defstruct CrossModeColor
  (r u8)
  (g u8)
  (b u8)
  (a u8))

(define (cross-mode-color-make [r : u8] [g : u8] [b : u8] [a : u8]) : CrossModeColor
  (CrossModeColor r g b a))

(define (cross-mode-color-use [color : CrossModeColor]) : i64
  (+
    (cast color.r : i64)
    (+
      (* (cast color.g : i64) 2)
      (+ (* (cast color.b : i64) 3) (* (cast color.a : i64) 4)))))

(define (main) : i64
  (let
    [color : CrossModeColor
      (cross-mode-color-make
        (cast 5 : u8)
        (cast 7 : u8)
        (cast 11 : u8)
        (cast 13 : u8))]
    [weighted : i64 (cross-mode-color-use color)]
    [sum : i64
      (+
        (cast color.r : i64)
        (+ (cast color.g : i64) (+ (cast color.b : i64) (cast color.a : i64))))]
    (begin
      (io.print-format "color={}:{}\n" weighted sum)
      (if (= weighted 104)
        (if (= sum 36)
          42
          2)
        1))))