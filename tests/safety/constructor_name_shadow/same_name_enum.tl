;; A module whose enum type shares the struct name below (#10004 C28).
(module same_name_enum)

(defenum Token
  (Word)
  (Punct))