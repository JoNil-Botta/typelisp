(defenum Item
  (Word String)
  (Gap))

(define (count-words [items : (&mut (Slice Item))]) : i64
  (match items
    [(slice (Item.Word _) & _) 1]
    [_ 0]))

(define (main) : i64
  (let
    [items : (Array Item 2) (array (Item.Word "a") Item.Gap)]
    (count-words (&mut items))))