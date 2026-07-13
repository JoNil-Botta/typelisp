;; A mutable-reference argument weakens to a tracked shared reborrow at typed
;; call sites. Scalar-returning calls end the borrow at the call; returned and
;; stored shared references retain it until their last use.
(defstruct ReborrowWorld
  (ticks i64)
  (sentinel i64))

(defstruct ReborrowView
  (:lifetimes source)
  (world (& source ReborrowWorld)))

(define (reborrow-count [world : (& seen ReborrowWorld)]) : i64
  world.ticks)

(define (reborrow-bump! [world : (&mut owner ReborrowWorld)]) : unit
  (set! world.ticks (+ world.ticks 1)))

(define (reborrow-shared [world : (& source ReborrowWorld)]) : (&
    source
    ReborrowWorld)
  world)

(define (reborrow-direct [world : (&mut world ReborrowWorld)]) : i64
  (reborrow-count world))

(define (reborrow-explicit [world : (&mut world ReborrowWorld)]) : i64
  (reborrow-count (& world)))

(define (reborrow-through-value [world : (&mut world ReborrowWorld)]) : i64
  (let
    [reader : (-> (& world ReborrowWorld) i64)
      (lambda ([item : (& world ReborrowWorld)]) : i64
        item.ticks)]
    (reader world)))

(define (reborrow-through-lambda [world : (&mut world ReborrowWorld)]) : i64
  ((lambda ([item : (& world ReborrowWorld)]) : i64
      item.ticks)
    world))

(define (reborrow-returned-then-bump! [world : (&mut world ReborrowWorld)]) : i64
  (let
    [returned : (& world ReborrowWorld) (reborrow-shared world)]
    [value : i64 returned.ticks]
    [_after-last-use : unit (reborrow-bump! world)]
    value))

(define (reborrow-stored-then-bump! [world : (&mut world ReborrowWorld)]) : i64
  (let
    [stored : (ReborrowView world) (ReborrowView world)]
    [value : i64 stored.world.ticks]
    [_after-last-use : unit (reborrow-bump! world)]
    value))

(define (reborrow-update [world : (&mut world ReborrowWorld)]) : unit
  (let
    [direct : i64 (reborrow-direct world)]
    [explicit : i64 (reborrow-explicit world)]
    [through-value : i64 (reborrow-through-value world)]
    [through-lambda : i64 (reborrow-through-lambda world)]
    [returned-value : i64 (reborrow-returned-then-bump! world)]
    [stored-value : i64 (reborrow-stored-then-bump! world)]
    (if (and
      (= direct 40)
      (= explicit 40)
      (= through-value 40)
      (= through-lambda 40)
      (= returned-value 40)
      (= stored-value 41)
      (= world.sentinel 7))
      unit
      (set! world.ticks 0))))

(define (main) : i64
  (let
    [world : ReborrowWorld (ReborrowWorld 40 7)]
    (begin
      (reborrow-update (&mut world))
      world.ticks)))