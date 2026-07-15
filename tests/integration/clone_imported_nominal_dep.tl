(module clone_imported_nominal_dep)

(defstruct Item
  (text String))

(defstruct Nested
  (item Item))

(defenum Tree
  (ImportedLeaf String)
  (ImportedBranch (Box Tree) (Box Tree)))

(defstruct RawItem
  (ptr (Ptr i64)))