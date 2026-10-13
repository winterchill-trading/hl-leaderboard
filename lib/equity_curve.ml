open! Core
open Hl_protocol

module Point = struct
  type t =
    { time_ms : int
    ; equity : float
    }
  [@@deriving sexp, compare, equal]
end

type t = Point.t list [@@deriving sexp_of]

let realized (f : User_fill.t) = Usd.to_float f.closed_pnl -. Usd.to_float f.fee

let of_fills ~account_value ~now_ms fills =
  let total = List.sum (module Float) fills ~f:realized in
  let start = account_value -. total in
  let first =
    match fills with
    | [] -> []
    | (f : User_fill.t) :: _ -> [ { Point.time_ms = f.time - 1; equity = start } ]
  in
  let _, points =
    List.fold fills ~init:(start, []) ~f:(fun (equity, acc) f ->
      let r = realized f in
      if Float.(r = 0.)
      then equity, acc
      else (
        let equity = equity +. r in
        equity, { Point.time_ms = f.time; equity } :: acc))
  in
  first @ List.rev points @ [ { Point.time_ms = now_ms; equity = account_value } ]
;;
