;; The dependency side of comptime_template_module_identity: its own `pick`,
;; a template that calls a private helper, and a template whose instance asks
;; for an instance of `pick` (#8597).
(define (helper [x : i64]) : i64
  (+ x 1000))

(define (pick [comptime T : type] [x : T]) : T
  x)

(define (bump [comptime T : type] [x : T]) : T
  (helper x))

(define (twice [comptime T : type] [x : T]) : T
  (+ (pick (type T) x) (pick (type T) x)))

(define (dep-pick) : i64
  (pick (type i64) 1))

(define (dep-bump) : i64
  (bump (type i64) 1))

(define (dep-twice) : i64
  (twice (type i64) 3))