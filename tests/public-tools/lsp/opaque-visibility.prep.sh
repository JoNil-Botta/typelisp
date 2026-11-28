mkdir -p "$FIXTURE_TMP/vault"
cat > "$FIXTURE_TMP/vault/types.tl" <<'TL'
(module vault.types)

(defstruct Whole (:opaque) (inner i64))
(defenum State (:opaque) (Hidden i64))
(defstruct Mixed [visible i64] (hidden i64 (:opaque)))
(defstruct Plain [visible i64])
(defstruct Borrowed (:lifetimes a) (value (& a i64)))
(defstruct Generic (:lifetimes a) (:opaque) (inner (Borrowed a)))

(define (make-mixed) : Mixed (Mixed 11 31))
TL
