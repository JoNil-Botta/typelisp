;; Dotted default aliases and explicit aliases must resolve one enum identity.
(import legacy_dotted_enum_provider)
(import legacy_dotted_enum_bridge)

(define (main) : i64
  (let
    [item : legacy_dotted_enum_provider.LegacyDottedEnum
      (legacy_dotted_enum_provider.LegacyDottedEnum.Value 42)]
    (+
      (match (legacy_dotted_enum_bridge.legacy-dotted-enum-roundtrip item)
        [(legacy_dotted_enum_provider.LegacyDottedEnum.Value value) value])
      (legacy_dotted_enum_bridge.legacy-dotted-struct-recursive-smoke))))