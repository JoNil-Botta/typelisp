(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(defenum Status
  (Ready)
  (Done)
  (Failed))

(extern (status-pick [arg0 : Status] [arg1 : Status] [choose-second : i64]) : Status (:symbol "tl_cabi_status_pick"))

(extern (status-eq [arg0 : Status] [arg1 : Status]) : i64 (:symbol "tl_cabi_status_eq"))

(extern status-pick-ptr (:symbol "tl_cabi_status_pick_ptr") : (->
  Status
  Status
  i64
  Status))

(define (status-rank [s : Status]) : i64
  (match s
    [Ready 1]
    [Done 2]
    [Failed 3]))

(define (main) : i64
  (let
    [pick-copy : (-> Status Status i64 Status) status-pick-ptr]
    [ready : Status (Ready)]
    [done : Status (Done)]
    [failed : Status (Failed)]
    [picked : Status (status-pick ready done 1)]
    [picked-via-ptr : Status (pick-copy ready failed 1)]
    [direct : i64 (status-eq picked done)]
    [via-ptr : i64 (status-eq picked-via-ptr failed)]
    [rank-total : i64
      (+ (status-rank ready) (+ (status-rank done) (status-rank failed)))]
    (begin
      (core/unless (= direct 1) (return 1))
      (core/unless (= via-ptr 1) (return 2))
      (core/unless (= rank-total 6) (return 3))
      42)))