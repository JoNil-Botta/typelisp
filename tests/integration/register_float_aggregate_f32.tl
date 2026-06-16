;; #2855: packed f32 fields in a homogeneous SSE eightbyte are register-resident.
;; Mixed integer/f32 sub-word eightbytes stay memory-backed.
(defstruct Vec2
  (x f32)
  (y f32))

(defstruct MixUF
  (tag u32)
  (value f32))

(define global-vec : Vec2
  (Vec2 2.0 3.0))
(define global-mix : MixUF
  (MixUF (cast 7 : u32) 8.5))

(define (vec-sum [v : Vec2]) : f32
  (+ (struct-get v x) (struct-get v y)))

(define (make-vec [x : f32] [y : f32]) : Vec2
  (Vec2 x y))

(define (choose-vec [take-left : bool]) : Vec2
  (if take-left
    (Vec2 1.25 2.75)
    (Vec2 9.0 10.0)))

(define (mix-tag [m : MixUF]) : u32
  (struct-get m tag))

(define (mix-value [m : MixUF]) : f32
  (struct-get m value))

;; Eight preceding f32 parameters exhaust SysV's xmm arg bank before `v`; they
;; also put `v` past Win64's four positional register slots.
(define (stack-vec
  [a : f32]
  [b : f32]
  [c : f32]
  [d : f32]
  [e : f32]
  [f : f32]
  [g : f32]
  [h : f32]
  [v : Vec2]) : f32
  (+ (+ a h) (vec-sum v)))

(define (case-vec-return) : bool
  (= (vec-sum (make-vec 1.5 2.5)) 4.0))

(define (case-vec-phi) : bool
  (= (vec-sum (choose-vec true)) 4.0))

(define (case-mixed) : bool
  (let
    [m : MixUF (MixUF (cast 11 : u32) 4.5)]
    (if (= (mix-tag m) (cast 11 : u32))
      (= (mix-value m) 4.5)
      false)))

(define (case-stack) : bool
  (= (stack-vec 1.0 2.0 3.0 4.0 5.0 6.0 7.0 8.0 (Vec2 9.0 10.0)) 28.0))

(define (case-global) : bool
  (begin
    (set! global-vec (make-vec 12.5 0.5))
    (set! global-mix (MixUF (cast 17 : u32) 1.5))
    (if (= (vec-sum global-vec) 13.0)
      (if (= (mix-tag global-mix) (cast 17 : u32))
        (= (mix-value global-mix) 1.5)
        false)
      false)))

(define (case-array) : bool
  (let
    [items : (Array Vec2) (make-array Vec2 2)]
    (begin
      (array-set! items 0 (Vec2 3.0 4.0))
      (array-set! items 1 (Vec2 5.0 6.0))
      (if (= (vec-sum (array-ref items 0)) 7.0)
        (= (struct-get (array-ref items 1) y) 6.0)
        false))))

(define (case-capture) : bool
  (let
    [v : Vec2 (Vec2 20.0 22.0)]
    [reader : (-> f32)
      (lambda () : f32
        (vec-sum v))]
    (= (reader) 42.0)))

(define (main) : i64
  (begin
    (unless (case-vec-return) (return 1))
    (unless (case-vec-phi) (return 2))
    (unless (case-mixed) (return 3))
    (unless (case-stack) (return 4))
    (unless (case-global) (return 5))
    (unless (case-array) (return 6))
    (unless (case-capture) (return 7))
    42))