(import stdlib.hash)
(import stdlib.eq)
(import stdlib.clone)

(defstruct DuplicateKey
  (text String))

(eq.gen DuplicateKey)

(hash.gen DuplicateKey)

(stdlib.clone.gen-clone DuplicateKey)