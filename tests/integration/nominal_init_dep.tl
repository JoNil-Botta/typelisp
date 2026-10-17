(defstruct Field
  (number i64)
  (text String))

(defenum Choice
  (First Field)
  (Last))

(defstruct Holder
  (field Field)
  (choice Choice))