;; A once closure (its body moves a capture out) may be called once on each
;; path.
(import stdlib.string)

(define (main) : i64
  (let
    [owned : String "forty-two-characters-long-string-value!!!!"]
    [take : (-> String)
      (lambda () : String
        owned)]
    [pick : bool true]
    (if pick
      (string.string-length (take))
      (+ 1 (string.string-length (take))))))