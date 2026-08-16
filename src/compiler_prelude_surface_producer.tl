;; compiler_prelude_surface_producer.tl - shared prelude/package surface helpers.
(import compiler_ast_types as ast)
(import compiler_surface_identity as surface_identity)
(import stdlib.string)
(import stdlib.vector)
(import (vector.vector String) as surface_svec)

(define (prelude-surface-path-present?
  [items : (& items surface_svec.Vec)]
  [path : String]) : bool
  (let
    [index : i64 0]
    [present : bool false]
    (begin
      (while (and (not present) (< index (surface_svec.len items)))
        (if (string.eq (surface_svec.get items index "") path)
          (set! present true)
          (set! index (+ index 1))))
      present)))

(define (prelude-surface-module-set [paths : ast.AstDeclPathList]) : (__tl_dyn-array
    String)
  (let
    [items : surface_svec.Vec (surface_svec.new)]
    [index : i64 0]
    [count : i64 (ast.ast-decl-path-list-len (& paths))]
    (begin
      (while (< index count)
        (let
          [path : String (array-ref paths.slots (+ paths.offset index))]
          (begin
            (if (prelude-surface-path-present? (& items) path)
              unit
              (surface_svec.push-ref! (&mut items) path))
            (set! index (+ index 1)))))
      (let
        [out (__tl_make-array String (surface_svec.len (& items)))]
        [copy-index : i64 0]
        [sort-index : i64 1]
        (begin
          (while (< copy-index (surface_svec.len (& items)))
            (begin
              (set!
                (array-ref out copy-index)
                (surface_svec.get (& items) copy-index ""))
              (set! copy-index (+ copy-index 1))))
          (while (< sort-index (array-length out))
            (let
              [value : String (array-ref out sort-index)]
              [scan : i64 sort-index]
              (begin
                (while (and
                  (> scan 0)
                  (surface_identity.surface-identity-string-less?
                    value
                    (array-ref out (- scan 1))))
                  (begin
                    (set! (array-ref out scan) (array-ref out (- scan 1)))
                    (set! scan (- scan 1))))
                (set! (array-ref out scan) value)
                (set! sort-index (+ sort-index 1)))))
          out)))))