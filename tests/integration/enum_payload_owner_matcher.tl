;; Match the provider's enums in a second module. Exhaustiveness must resolve
;; their raw payload declaration types in the provider module, not here.
(import enum_payload_owner_provider as owner)

(define (alias-score [choice : owner.Choice]) : i64
  (match choice
    [(owner.Choice.Some (owner.Payload value)) value]
    [(owner.Choice.None) 0]))

(define (full-name-score [choice : enum_payload_owner_provider.Choice]) : i64
  (match choice
    [(enum_payload_owner_provider.Choice.Some
        (enum_payload_owner_provider.Payload value))
      value]
    [(enum_payload_owner_provider.Choice.None) 0]))

(define (lifetime-score [choice : (owner.RefChoice source)]) : i64
  (match choice
    [(owner.RefChoice.RefSome (owner.RefPayload value)) (deref value)]
    [(owner.RefChoice.RefNone) 0]))

(define (run) : i64
  (let
    [borrowed : i64 21]
    (+
      (alias-score (owner.Choice.Some (owner.Payload 20)))
      (+
        (full-name-score
          (enum_payload_owner_provider.Choice.Some
            (enum_payload_owner_provider.Payload 1)))
        (lifetime-score
          (owner.RefChoice.RefSome (owner.RefPayload (& borrowed))))))))