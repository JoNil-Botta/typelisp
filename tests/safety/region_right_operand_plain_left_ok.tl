;; Pins the operators SPEC 3.9's implementation note names: `+` and `-` with a
;; plain left operand give the plain type, whatever the right operand's tag.
;; The note calls this a checker gap, so a change here updates the note too.
(define (read-i64 [p : (& p i64)]) : (in p i64)
  (deref p))

(define (add-literal [p : (& p i64)]) : i64
  (+ 2 (read-i64 p)))

(define (add-name [p : (& p i64)] [x : i64]) : i64
  (+ x (read-i64 p)))

(define (sub-literal [p : (& p i64)]) : i64
  (- 0 (read-i64 p)))

(define (sub-name [p : (& p i64)] [x : i64]) : i64
  (- x (read-i64 p)))

(define (main) : i64
  (let
    [z : i64 40]
    (- (+ (add-literal (& z)) (add-name (& z) 0)) (+ (sub-name (& z) 40) 40))))