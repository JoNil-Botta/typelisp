(import stdlib.clone as clone_gen)

(defstruct Node
  (next (Box Node)))

(clone_gen.gen-clone Node)