(defstruct Label
  (text String)
  (code i64))

(define (main) : i64
  (let
    [items : (Array Label 2) (array (Label "first" 0) (Label "second" 1))]
    (match (& items)
      [(array (Label text _) _)
        (set! (array-ref items 0) (Label "changed" 2))
        (__tl_string_length text)])))