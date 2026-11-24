;; #9257: `text_buf.text-buf-store-entry-at` was removed so safe code cannot
;; launder `(& TextBufStringStore) -> String` or read out of bounds.
(import stdlib.text_buf)

(define (main) : i64
  (let
    [store : (Box text_buf.TextBufStringStore) (text_buf.text-buf-store-new)]
    [_entry : String (text_buf.text-buf-store-entry-at (& (deref store)) 0)]
    0))