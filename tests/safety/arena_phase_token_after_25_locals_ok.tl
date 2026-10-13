;: An arena phase token stays direct however many locals precede it: binding
;: it can cross the type environment's local-cache threshold (25 earlier locals
;: put a cache layer between the token and its markers), which must not hide
;: the token from `arena.rewind-safe!`.
(import stdlib.arena)

(define (main) : i64
  (let
    [scratch : arena.Arena (arena.make)]
    [_v0 : i64 0]
    [_v1 : i64 1]
    [_v2 : i64 2]
    [_v3 : i64 3]
    [_v4 : i64 4]
    [_v5 : i64 5]
    [_v6 : i64 6]
    [_v7 : i64 7]
    [_v8 : i64 8]
    [_v9 : i64 9]
    [_v10 : i64 10]
    [_v11 : i64 11]
    [_v12 : i64 12]
    [_v13 : i64 13]
    [_v14 : i64 14]
    [_v15 : i64 15]
    [_v16 : i64 16]
    [_v17 : i64 17]
    [_v18 : i64 18]
    [_v19 : i64 19]
    [_v20 : i64 20]
    [_v21 : i64 21]
    [_v22 : i64 22]
    [_v23 : i64 23]
    [_v24 : i64 24]
    [phase : arena.ArenaPhase (arena.phase scratch)]
    (arena.rewind-safe! phase)
    (arena.destroy-safe! scratch)
    42))