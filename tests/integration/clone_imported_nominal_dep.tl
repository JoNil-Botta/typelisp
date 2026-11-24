(module clone_imported_nominal_dep)

(import stdlib.clone as clone_gen)
(import stdlib.string)

(defstruct Item
  (text String))

(defstruct Nested
  (item Item))

(defenum Tree
  (ImportedLeaf String)
  (ImportedBranch (Box Tree) (Box Tree)))

(clone_gen.gen-clone Item)

(clone_gen.gen-clone Nested)

;; gen-clone does not follow a recursive type, so the owner writes its hook.
(define (clone-tree [tree : (& Tree)]) : Tree
  (match tree
    [(ImportedLeaf text) (ImportedLeaf (string.copy text))]
    [(ImportedBranch left right)
      (ImportedBranch (box (clone-tree left)) (box (clone-tree right)))]))

(defstruct RawItem
  (ptr (Ptr i64)))