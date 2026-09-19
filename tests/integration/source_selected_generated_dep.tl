;; Every export selected by `source_selected_generated_export` is emitted by a
;; module-scope declaration macro, so none exists in the parsed declarations.
(import source_selected_generated_macro_dep as gen)

(defmacro (emit-exports) : Decls
  `(begin
    (define answer : i64
      20)
    (define (twice [x : i64]) : i64
      (* x 2))
    (defstruct Pair
      (left i64)
      (right i64))
    (defenum Shape
      (Dot)
      (Line i64))))

(emit-exports)

(gen.emit-scaled scaled 3)

(gen.emit-outer)

(cfg
  linux
  (defmacro (emit-host) : Decls
    `(define host-bias : i64
      1)))

(cfg
  windows
  (defmacro (emit-host) : Decls
    `(define host-bias : i64
      1)))

(emit-host)