(defstruct Label
  (text String)
  (code i64))

(define (main) : i64
  (let
    [label : Label (Label "forty" 2)]
    (match (& label)
      [(Label text _)
        (begin
          (set! label (Label "other" 3))
          (__tl_string_length text))])))