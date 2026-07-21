;; Legacy path imports flatten both modules, while the bridge refers to the
;; provider through a dotted alias. Both views must resolve one enum identity.
(import "legacy_dotted_enum_provider.tl")
(import "legacy_dotted_enum_bridge.tl")

(define (main) : i64
  (let
    [item : LegacyDottedEnum (LegacyDottedEnum.Value 42)]
    [struct-item : LegacyDottedStruct (LegacyDottedStruct 0)]
    (+
      (match (legacy-dotted-enum-roundtrip item)
        [(LegacyDottedEnum.Value value) value])
      (legacy-dotted-enum-countdown (& struct-item) 0))))