(module spmd_fixture)

;; The consumer package exercises dependency-catalog selection after ordinary
;; qualified resolution chooses these physical source declarations. The three
;; result policies share one native dependency catalog and must stay byte-for-
;; byte equivalent to forced-source CTFE.
(defmacro (package-answer) : i64
  `42)

(defmacro (package-increment [value : i64]) : i64
  `(+ ,value 1))

(defmacro (package-module) : Module
  `(begin
    (module fixture.generated)
    (define (answer) : i64
      41)))

(defmacro (package-decls) : Decls
  `(begin
    (define (package-decl-answer) : i64
      40)
    (unsafe
      (define (package-unsafe-answer [value : i64]) : i64
        value))))

;; Keep one intentionally unsupported producer shape in the catalog. Its first
;; native attempt learns the mapping-generation shell and its second call must
;; bypass both dispatch and host-session setup before deterministic source CTFE.
(defmacro (package-unsupported [value : Expr]) : Expr
  (match value
    [(comptime.Expr.If condition _ _) condition]
    [_ value]))

(define (helper [x : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result varying)
      (index-param 0)))
  : i64
  (+ x scale))

(define (shifted [x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result varying)
      (index-param none)))
  : i64
  (+ x 5))

(define (positive? [x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result varying)
      (index-param 0)))
  : bool
  (> x 5))

(define (constant [_x : i64] [value : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : i64
  value)

(define (constant-i16 [_x : i16] [value : i16])
  (:spmd-callable
    (specialization
      (lanes 32)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : i16
  value)

(define (constant-u16 [_x : u16] [value : u16])
  (:spmd-callable
    (specialization
      (lanes 32)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : u16
  value)

(define (constant-i8 [_x : i8] [value : i8])
  (:spmd-callable
    (specialization
      (lanes 64)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : i8
  value)

(define (constant-u8 [_x : u8] [value : u8])
  (:spmd-callable
    (specialization
      (lanes 64)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : u8
  value)

(define (literal-constant [_x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result uniform)
      (index-param none)))
  : i64
  7)

(define (cast-constant [_x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result uniform)
      (index-param none)))
  : i64
  (cast 11 : i64))

(define (sink [_x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result unit)
      (index-param none)))
  : unit
  unit)

(define (add-f64 [x : f64] [scale : f64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result varying)
      (index-param none)))
  : f64
  (+ x scale))

(define (add-f32 [x : f32] [scale : f32])
  (:spmd-callable
    (specialization
      (lanes 16)
      (args varying uniform)
      (result varying)
      (index-param none)))
  : f32
  (+ x scale))