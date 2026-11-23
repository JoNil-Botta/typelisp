(import stdlib.clone)

(defstruct DuplicateKey
  (text String))

(stdlib.clone.gen-clone DuplicateKey)