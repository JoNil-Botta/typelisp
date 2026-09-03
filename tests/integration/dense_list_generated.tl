;; Native/source expansion witness for the reusable dense-list generator.
(import stdlib.dense_list)

(defstruct DenseListGenerated
  (slots (__tl_dyn-array i64))
  (len i64))

(dense_list.compiler-dense-list-operations
  i64
  DenseListGenerated
  dense-list-generated
  caller-provided-fallback
  zero-capacity
  len
  empty?
  append-from)

(define (main) : i64
  (let
    [source : DenseListGenerated (dense-list-generated-new)]
    [out : DenseListGenerated (dense-list-generated-new)]
    (begin
      (dense-list-generated-push (&mut source) 19)
      (dense-list-generated-push (&mut source) 23)
      (dense-list-generated-append-from (&mut out) (& source) 0)
      (if (and
        (= (dense-list-generated-len (& out)) 2)
        (not (dense-list-generated-empty? (& out))))
        (+
          (dense-list-generated-get (& out) 0 0)
          (dense-list-generated-get (& out) 1 0))
        1))))