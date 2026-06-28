;; compile_profile_generated_replay_lazy.tl - generated-module replay should not
;; re-expand nested declaration macros when the direct structural comparison is
;; already identical.
(defstruct ReplayProfileAddress
  (zip i64))

(defstruct ReplayProfilePerson
  (home ReplayProfileAddress))

(defmacro (profile-replay-leaf [T : type]) : Module
  `(begin
    (module generated.profile_replay_leaf)
    (defenum Result
      (Ok ,T)
      (Err String))
    (define (make) : ,T
      (init : ,T))))

(defmacro (profile-replay-nested [T : type] [index-expr : Expr]) : Decls
  (match index-expr
    [(ExprInt index)
      (if (>= index (struct-field-count T))
        `(begin)
        (let
          [field-type : Expr (struct-field-type T index)]
          [field-kind : String (type-kind field-type)]
          [next-index : Expr (expr-int (+ index 1))]
          (match field-kind
            ["struct"
              `(begin
                (profile-replay-nested ,T ,next-index)
                (import (profile-replay-leaf ,field-type) as nested))]
            [_ `(profile-replay-nested ,T ,next-index)])))]
    [_ `(begin)]))

(defmacro (profile-replay-user [T : type]) : Module
  `(begin
    (module generated.profile_replay_user)
    (profile-replay-nested ,T 0)
    (define (answer) : i64
      42)))

(import (profile-replay-leaf ReplayProfileAddress) as address_leaf)
(import (profile-replay-user ReplayProfilePerson) as replay_user)
(import (profile-replay-user ReplayProfilePerson) as replay_user_again)

(define (main) : i64
  (replay_user_again.answer))