(import clone_imported_nominal_dep as dep)
(import stdlib.string)
(import stdlib.clone as clone_gen)

(defstruct Wrapper
  (item dep.Item)
  (nested dep.Nested)
  (tree dep.Tree))

(defenum LocalOutcome
  (ImportedItem dep.Item)
  (ImportedWrapper Wrapper)
  (LocalNested (Box LocalOutcome)))

(clone_gen.gen-clone Wrapper)

;; gen-clone does not follow a recursive type, so the owner writes its hook.
(define (clone-local-outcome [outcome : (& LocalOutcome)]) : LocalOutcome
  (match outcome
    [(ImportedItem item) (ImportedItem (dep.clone-item item))]
    [(ImportedWrapper wrapper) (ImportedWrapper (clone-wrapper wrapper))]
    [(LocalNested inner) (LocalNested (box (clone-local-outcome inner)))]))

(define (make-wrapper [tag : String]) : Wrapper
  (Wrapper
    (dep.Item (string.copy (& tag)))
    (dep.Nested (dep.Item (string.append (string.copy (& tag)) ":nested")))
    (ImportedBranch
      (box (dep.ImportedLeaf (string.append (string.copy (& tag)) ":left")))
      (box (dep.ImportedLeaf (string.append tag ":right"))))))

(define (tree-ok? [tree : dep.Tree] [tag : String]) : bool
  (match tree
    [(ImportedLeaf _) false]
    [(ImportedBranch left right)
      (match (__tl-box-place left)
        [(ImportedLeaf left-text)
          (match (__tl-box-place right)
            [(ImportedLeaf right-text)
              (and
                (string.eq left-text (string.append tag ":left"))
                (string.eq right-text (string.append tag ":right")))]
            [(ImportedBranch _ _) false])]
        [(ImportedBranch _ _) false])]))

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