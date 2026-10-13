open! Core
open! Async
open Hl_protocol

let names = [ "user"; "agent"; "vault"; "subAccount"; "missing" ]
let default = [ "user" ]

let arg_type =
  Command.Arg_type.create (fun s ->
    if List.mem names s ~equal:String.equal
    then s
    else raise_s [%message "unknown role" s ~expected:(names : string list)])
;;

let accepts ~roles = function
  | None -> false
  | Some role -> List.mem roles (User_role.Role.to_string role) ~equal:String.equal
;;

let candidates ?min_account_value board ~n ~windows ~roles ~role_of =
  let known = Address.Table.create () in
  let role (row : Board.Row.t) =
    match Hashtbl.find known row.eth_address with
    | Some role -> return role
    | None ->
      let%map role = role_of row.eth_address in
      Hashtbl.set known ~key:row.eth_address ~data:role;
      role
  in
  let selected = Address.Hash_set.create () in
  let candidates = Queue.create () in
  let excluded = Queue.create () in
  let rec walk rows ~taken =
    match rows with
    | _ when taken >= n -> return ()
    | [] -> return ()
    | (row : Board.Row.t) :: rest ->
      if Hash_set.mem selected row.eth_address
      then walk rest ~taken:(taken + 1)
      else (
        match%bind role row with
        | r when accepts ~roles r ->
          Hash_set.add selected row.eth_address;
          Queue.enqueue candidates row;
          walk rest ~taken:(taken + 1)
        | r ->
          if not
               (Queue.exists excluded ~f:(fun ((x : Board.Row.t), _) ->
                  Address.equal x.eth_address row.eth_address))
          then Queue.enqueue excluded (row, r);
          walk rest ~taken)
  in
  let%map () =
    Deferred.List.iter ~how:`Sequential windows ~f:(fun window ->
      walk (Board.top ?min_account_value board ~window ~n:Int.max_value) ~taken:0)
  in
  Queue.to_list candidates, Queue.to_list excluded
;;
