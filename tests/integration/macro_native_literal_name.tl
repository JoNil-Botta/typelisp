;; A stdlib macro that builds a use-site name from a string literal,
;; `(comptime.expr-var "value")`, names the caller's binding of that spelling
;; in native (embedded TLCI) expansion exactly as in interpreted CTFE (#9681).
;; `gen-clone`'s struct and enum roots read the generated function's own
;; `value` parameter that way, so a native-mode compiler that treated the
;; literal as a template name would report it unbound.
(module macro_native_literal_name)

(import stdlib.string)
(import stdlib.clone as clone_gen)

(defstruct Point
  (label String)
  (x i64)
  (y i64))

(clone_gen.gen-clone Point)

(defenum Shape
  (Dot Point)
  (Line Point Point)
  (Empty))

(clone_gen.gen-clone Shape)

(define (main) : i64
  (let
    [value : Point (Point (string.append "o" "rigin") 3 4)]
    [copy : Point (clone value)]
    [shape : Shape (Line (clone value) (Point (string.append "e" "nd") 10 20))]
    [shape-copy : Shape (clone shape)]
    [line-sum : i64
      (match shape-copy
        [(Line a b) (+ a.x a.y b.x b.y)]
        [_ 0])]
    ;; 3 + 4 + 37 - |"origin"| = 38
    (+ (- (+ copy.x copy.y line-sum) (string.string-length copy.label)) 4)))