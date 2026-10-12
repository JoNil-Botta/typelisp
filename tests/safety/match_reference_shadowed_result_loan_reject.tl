;; The escaping view still borrows the outer `label`, hidden by its pattern.
(defstruct Label
  (text String))

(define (main) : i64
  (let
    [label : Label (Label "before")]
    [saved : (& label str)
      (match (& label)
        [(Label label) label])]
    (begin
      (set! label (Label "after"))
      (__tl_string_length saved))))