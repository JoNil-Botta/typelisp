(import stdlib.clone as clone_gen)

(defstruct Leaf
  (value String))

(defstruct Holder
  (leaf Leaf))

(clone_gen.gen-clone Holder)