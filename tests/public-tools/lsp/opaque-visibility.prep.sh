mkdir -p "$FIXTURE_TMP/vault"
cat > "$FIXTURE_TMP/vault/types.tl" <<'TL'
(module vault.types)

(defstruct Whole (:opaque) (inner i64))
(defenum State (:opaque) (Hidden i64))
(defstruct Mixed (visible i64) (hidden i64 (:opaque)))

(define (make-mixed) : Mixed (Mixed 11 31))
TL
