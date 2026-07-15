(import clone_imported_nominal_dep as dep)
(import stdlib.string)

(defstruct Wrapper
  (item dep.Item)
  (nested dep.Nested)
  (tree dep.Tree))

(defenum LocalOutcome
  (ImportedItem dep.Item)
  (ImportedWrapper Wrapper)
  (LocalNested (Box LocalOutcome)))

(define (make-wrapper [tag : String]) : Wrapper
  (Wrapper
    (dep.Item tag)
    (dep.Nested (dep.Item (string.append tag ":nested")))
    (dep.ImportedBranch
      (box (dep.ImportedLeaf (string.append tag ":left")))
      (box (dep.ImportedLeaf (string.append tag ":right"))))))

(define (tree-ok? [tree : dep.Tree] [tag : String]) : bool
  (match tree
    [(dep.ImportedLeaf _) false]
    [(dep.ImportedBranch left right)
      (match (box-get left)
        [(dep.ImportedLeaf left-text)
          (match (box-get right)
            [(dep.ImportedLeaf right-text)
              (and
                (string.eq left-text (string.append tag ":left"))
                (string.eq right-text (string.append tag ":right")))]
            [(dep.ImportedBranch _ _) false])]
        [(dep.ImportedBranch _ _) false])]))

(define (wrapper-ok? [value : Wrapper] [tag : String]) : bool
  (and
    (string.eq value.item.text tag)
    (string.eq value.nested.item.text (string.append tag ":nested"))
    (tree-ok? value.tree tag)))

(define (scratch-outcome [tag : String]) : LocalOutcome
  (with-scratch (ImportedWrapper (make-wrapper tag))))

(define (main) : i64
  (let
    [value : Wrapper (make-wrapper "clone-imported")]
    [copied : Wrapper (clone value)]
    [scratch : LocalOutcome (scratch-outcome "scratch-imported")]
    (if (and
      (wrapper-ok? copied "clone-imported")
      (match scratch
        [(ImportedItem _) false]
        [(ImportedWrapper wrapped) (wrapper-ok? wrapped "scratch-imported")]
        [(LocalNested _) false]))
      42
      1)))