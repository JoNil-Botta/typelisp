;; Transitional bridge for documentation-owned generated string vectors that
;; still call compiler/load internals expecting the legacy stdlib.vector API.
(import stdlib.vector)
(import (vector.vector String) as doc_svec)

(define (doc-string-vec-to-legacy [roots : (& roots doc_svec.Vec)]) : vector.StringVec
  (let
    [count : i64 (doc_svec.len roots)]
    [index : i64 0]
    [legacy : vector.StringVec (vector.string-vec-new)]
    (begin
      (while (< index count)
        (begin
          (set!
            legacy
            (vector.string-vec-push legacy (doc_svec.get roots index "")))
          (set! index (+ index 1))))
      legacy)))

(define (doc-string-vec-from-legacy [roots : vector.StringVec]) : doc_svec.Vec
  (let
    [count : i64 (vector.string-vec-len (& roots))]
    [index : i64 0]
    [out : doc_svec.Vec (doc_svec.new)]
    (begin
      (while (< index count)
        (begin
          (doc_svec.push (&mut out) (vector.string-vec-get (& roots) index ""))
          (set! index (+ index 1))))
      out)))