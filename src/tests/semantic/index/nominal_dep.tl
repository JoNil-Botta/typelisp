(module semantic.index.nominal_dep)

(defstruct ImportedBox
  (value i64))

(defenum ImportedChoice
  (ImportedNone)
  (ImportedSome ImportedBox))