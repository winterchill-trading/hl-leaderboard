open! Core

module Series = struct
  type t =
    { account_value : (int * float) list
    ; pnl : (int * float) list
    ; vlm : float
    }
  [@@deriving sexp_of]
end

type t = (string * Series.t) list [@@deriving sexp_of]

let number = function
  | `String s -> Float.of_string s
  | `Float f -> f
  | `Int i -> Float.of_int i
  | json -> raise_s [%message "not a number" (Yojson.Safe.to_string json)]
;;

let points = function
  | `List l ->
    List.map l ~f:(function
      | `List [ `Int t; v ] -> t, number v
      | `List [ `Float t; v ] -> Float.to_int t, number v
      | json -> raise_s [%message "bad history point" (Yojson.Safe.to_string json)])
  | `Null -> []
  | json -> raise_s [%message "bad history" (Yojson.Safe.to_string json)]
;;

let series json =
  let open Yojson.Safe.Util in
  { Series.account_value = points (member "accountValueHistory" json)
  ; pnl = points (member "pnlHistory" json)
  ; vlm =
      (match member "vlm" json with
       | `Null -> 0.
       | v -> number v)
  }
;;

let of_string s =
  Or_error.try_with (fun () ->
    match Yojson.Safe.from_string s with
    | `List windows ->
      List.map windows ~f:(function
        | `List [ `String name; body ] -> name, series body
        | json -> raise_s [%message "bad portfolio window" (Yojson.Safe.to_string json)])
    | json -> raise_s [%message "portfolio is not a list" (Yojson.Safe.to_string json)])
  |> Or_error.tag ~tag:"portfolio"
;;

let find t name = List.Assoc.find t name ~equal:String.equal

let request user =
  `Assoc
    [ "type", `String "portfolio"; "user", `String (Hl_protocol.Address.to_string user) ]
;;

let equity_curve (s : Series.t) =
  match s.account_value, s.pnl with
  | (_, start) :: _, (_ :: _ as pnl) when Float.(start > 0.) ->
    let base =
      match pnl with
      | (_, p0) :: _ -> p0
      | [] -> 0.
    in
    Some
      (List.map pnl ~f:(fun (time_ms, p) ->
         { Equity_curve.Point.time_ms; equity = start +. (p -. base) }))
  | _ -> None
;;
