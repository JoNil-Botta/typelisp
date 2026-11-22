(import enum_same_name_provider as provider)

(define (main) : i64
  (match (provider.Same.Same 41)
    [(enum_same_name_provider.Same.Same value)
      (match enum_same_name_provider.Empty.Empty
        [provider.Empty.Empty (+ value 1)])]))