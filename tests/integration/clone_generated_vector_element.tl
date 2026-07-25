;; Regression: cloning a type that holds a generated vector whose element needs a
;; synthesized clone helper. A generated vector module splices the element's
;; UNQUALIFIED name into declarations living in the generated module's namespace,
;; so the clone-root walk must resolve it to the key the clone-able set accepted
;; it under. Before the fix it resolved only to the generated module's key, the
;; element never became a clone root, and lowering failed with
;; `lower: missing generated clone helper for VecItem`.
;;
;; Both conditions matter: the clone must happen in the SAME module that
;; instantiates the vector (an imported nominal takes a different path), and the
;; element must actually require a helper (an all-scalar struct never reaches the
;; failing dispatch). Refs #5719.
(import stdlib.vector)
(import stdlib.string)

(defstruct VecItem
  (n i64)
  (label String))

(import (vector.vector VecItem core) as vec_item_vec)

(defstruct VecItemBag
  (items vec_item_vec.Vec))

(define (bag-with-two) : VecItemBag
  (let
    [items : vec_item_vec.Vec (vec_item_vec.with-capacity 2)]
    (begin
      (vec_item_vec.push (&mut items) (VecItem 7 (string.copy "first")))
      (vec_item_vec.push (&mut items) (VecItem 9 (string.copy "second")))
      (VecItemBag items))))

(define (bag-sum [bag : (& bag VecItemBag)]) : i64
  (let
    [i : i64 0]
    [n : i64 (vec_item_vec.len (& (struct-get bag items)))]
    [acc : i64 0]
    (begin
      (while (< i n)
        (begin
          (set!
            acc
            (+
              acc
              (struct-get
                (array-ref (vec_item_vec.slots (& (struct-get bag items))) i)
                n)))
          (set! i (+ i 1))))
      acc)))

(define (main) : i64
  (let
    [original : VecItemBag (bag-with-two)]
    [copy : VecItemBag (clone original)]
    ;; 7 + 9 = 16 from each bag; the String field is what forces a
    ;; synthesized element clone helper.
    [original-sum : i64 (bag-sum (& original))]
    [copy-sum : i64 (bag-sum (& copy))]
    (if (and (= original-sum 16) (= copy-sum 16))
      42
      1)))