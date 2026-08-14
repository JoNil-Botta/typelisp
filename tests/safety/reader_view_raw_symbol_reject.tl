;; Reader traversal symbols carry nominal mixed syntax identities. A raw
;; compiler integer cannot cross this boundary without explicit checked ingress.
(import read as reader)

(define (main) : i64
  (let
    [raw : i64 17]
    [view : reader.SexprView (reader.SexprView.Sym raw)]
    (match view
      [(reader.SexprView.Sym _) 0]
      [_ 1])))