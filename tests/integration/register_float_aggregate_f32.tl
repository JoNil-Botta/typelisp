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
  (+ v.x v.y))

(define (make-vec [x : f32] [y : f32]) : Vec2
  (Vec2 x y))

(define (choose-vec [take-left : bool]) : Vec2
  (if take-left
    (Vec2 1.25 2.75)
    (Vec2 9.0 10.0)))

(define (mix-tag [m : MixUF]) : u32
  m.tag)

(define (mix-value [m : MixUF]) : f32
  m.value)

;; Eight preceding f32 parameters exhaust SysV's xmm arg bank before `v`; they
;; also put `v` past Win64's four positional register slots.
(define (stack-vec
  [a : f32]
  [_b : f32]
  [_c : f32]
  [_d : f32]
  [_e : f32]
  [_f : f32]
  [_g : f32]
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
  (set! global-vec (make-vec 12.5 0.5))
  (set! global-mix (MixUF (cast 17 : u32) 1.5))
  (if (= (vec-sum global-vec) 13.0)
    (if (= (mix-tag global-mix) (cast 17 : u32))
      (= (mix-value global-mix) 1.5)
      false)
    false))

(define (case-array) : bool
  (let
    [items : (__tl_dyn-array Vec2) (__tl_make-array Vec2 2)]
    (set! (array-ref items 0) (Vec2 3.0 4.0))
    (set! (array-ref items 1) (Vec2 5.0 6.0))
    (if (= (vec-sum (array-ref items 0)) 7.0)
      (= (__tl-project-field (array-ref items 1) y) 6.0)
      false)))

(define (case-capture) : bool
  (let
    [v : Vec2 (Vec2 20.0 22.0)]
    [reader : (-> f32)
      (lambda () : f32
        (vec-sum v))]
    (= (reader) 42.0)))

;; #8964: packed f32 field mutation surviving a call (held in a GP carrier
;; across the call), f64 control, spilled carrier, and bit-exact preservation
;; including `-0.0` and nontrivial bit patterns.
(define (clobber-floats [k : i64] [a : f64] [b : f64]) : f64
  (let
    [acc : f64 (+ a b)]
    [i : i64 0]
    (while (< i k)
      (set! acc (+ (* acc 0.5) 1.25))
      (set! i (+ i 1)))
    acc))

(define (is-neg-zero-f32 [x : f32]) : bool
  (and (= x 0.0) (< (/ 1.0 x) 0.0)))

(define (is-pos-zero-f32 [x : f32]) : bool
  (and (= x 0.0) (> (/ 1.0 x) 0.0)))

(define (case-field-assign-across-call) : bool
  (let
    [p : Vec2 (Vec2 1.0 2.0)]
    [ctrl : f64 3.625]
    (set! p.x 7.5)
    (let
      [sink : f64 (clobber-floats 4 1.5 2.5)]
      (and (> sink 0.0) (= p.x 7.5) (= p.y 2.0) (= ctrl 3.625)))))

(define (case-bit-patterns-across-call) : bool
  (let
    ;; Produce runtime +/-0.0 so opt1/opt2 keep the IEEE sign bit distinct.
    [rt-zero : f32 (cast (- (clobber-floats 1 0.0 0.0) 1.25) : f32)]
    [nz : f32 (neg rt-zero)]
    [pz : f32 rt-zero]
    [p1 : Vec2 (Vec2 nz (cast 0.33333334 : f32))]
    [p2 : Vec2 (Vec2 (cast -3.75 : f32) nz)]
    [p3 : Vec2 (Vec2 pz (cast 12345.625 : f32))]
    (set! p2.x (cast -17.125 : f32))
    (let
      [sink : f64 (clobber-floats 3 2.0 4.0)]
      [p-spilled : Vec2 (Vec2 p1.x p2.y)]
      (and
        (> sink 0.0)
        (is-neg-zero-f32 p1.x)
        (= p1.y (cast 0.33333334 : f32))
        (= p2.x (cast -17.125 : f32))
        (is-neg-zero-f32 p2.y)
        (is-pos-zero-f32 p3.x)
        (= p3.y (cast 12345.625 : f32))
        (is-neg-zero-f32 p-spilled.x)
        (is-neg-zero-f32 p-spilled.y)))))

(define (main) : i64
  (unless (case-vec-return) (return 1))
  (unless (case-vec-phi) (return 2))
  (unless (case-mixed) (return 3))
  (unless (case-stack) (return 4))
  (unless (case-global) (return 5))
  (unless (case-array) (return 6))
  (unless (case-capture) (return 7))
  (unless (case-field-assign-across-call) (return 8))
  (unless (case-bit-patterns-across-call) (return 9))
  42)