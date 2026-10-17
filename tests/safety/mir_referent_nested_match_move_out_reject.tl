;; A match inside another match's arm moving a payload out from behind a
;; shared reference is rejected too: an arm's error is the whole match's.
(import stdlib.string)

(defenum MaybeText
  (Some String)
  (No))

(defstruct Names
  (alias MaybeText)
  (fallback MaybeText))

(define (alias [names : (& names Names)]) : String
  (match names.alias
    [(MaybeText.Some text) (string.copy (& text))]
    [(MaybeText.No)
      (match names.fallback
        [(MaybeText.Some text) text]
        [(MaybeText.No) (string.copy "")])]))

(define (main) : i64
  (let
    [names : Names (Names MaybeText.No (MaybeText.Some (string.copy "abc")))]
    (string.string-length (alias (& names)))))