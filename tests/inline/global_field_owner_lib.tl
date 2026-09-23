(defstruct ImportedLeaf
  (value i64))

(defstruct ImportedOwner
  (leaf ImportedLeaf))

(define imported-seed : i64
  40)
(define imported-owner : ImportedOwner
  (ImportedOwner (ImportedLeaf (+ imported-seed 2))))

(define (read-imported-field) : i64
  imported-owner.leaf.value)