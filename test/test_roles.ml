open! Core
open! Async
open Hl_leaderboard
open Hl_protocol

let board () =
  In_channel.read_all "fixtures/leaderboard.json" |> Board.of_string |> Or_error.ok_exn
;;

let vault = Address.of_string "0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf"
let sub_account = Address.of_string "0x399965e15d4e61ec3529cc98b7f7ebb93b733336"

let role_of ~asked address =
  Queue.enqueue asked address;
  return
    (Some
       (if Address.equal address vault
        then User_role.Role.Vault
        else if Address.equal address sub_account
        then Sub_account { master = vault }
        else User))
;;

let run ~roles =
  let asked = Queue.create () in
  let%map candidates, excluded =
    Roles.candidates
      (board ())
      ~n:2
      ~windows:[ Week; All_time ]
      ~roles
      ~role_of:(role_of ~asked)
  in
  print_s
    [%message
      ""
        ~candidates:
          (List.map candidates ~f:(fun (r : Board.Row.t) -> r.eth_address)
           : Address.t list)
        ~excluded:
          (List.map excluded ~f:(fun ((r : Board.Row.t), role) -> r.eth_address, role)
           : (Address.t * User_role.Role.t option) list)
        ~asked:(Queue.to_list asked : Address.t list)]
;;

let%expect_test "vaults and sub-accounts make room for the next rows" =
  (* Week ranking: vault, f5d8, sub-account, 8c62, ...; all time: vault, sub-account,
     8c62, 85ec, ... *)
  let%bind () = run ~roles:Roles.default in
  [%expect
    {|
    ((candidates
      (0xf5d81a135f756ca16544e53c20fc20643ec3ad53
       0x8c625ff57d8a4374784c7eff585dfdc42ccec974
       0x85ecf584f25db6f146718b86d493e33c5af72052))
     (excluded
      ((0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf (Vault))
       (0x399965e15d4e61ec3529cc98b7f7ebb93b733336
        ((Sub_account (master 0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf))))))
     (asked
      (0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
       0xf5d81a135f756ca16544e53c20fc20643ec3ad53
       0x399965e15d4e61ec3529cc98b7f7ebb93b733336
       0x8c625ff57d8a4374784c7eff585dfdc42ccec974
       0x85ecf584f25db6f146718b86d493e33c5af72052)))
    |}];
  let%bind () = run ~roles:Roles.names in
  [%expect
    {|
    ((candidates
      (0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
       0xf5d81a135f756ca16544e53c20fc20643ec3ad53
       0x399965e15d4e61ec3529cc98b7f7ebb93b733336))
     (excluded ())
     (asked
      (0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf
       0xf5d81a135f756ca16544e53c20fc20643ec3ad53
       0x399965e15d4e61ec3529cc98b7f7ebb93b733336)))
    |}];
  return ()
;;

let%expect_test "accepting every role selects what Board.candidates selects" =
  let board = board () in
  Deferred.List.iter ~how:`Sequential [ 1; 2; 3; 6 ] ~f:(fun n ->
    let windows = Board.Window.all in
    let%map selected, excluded =
      Roles.candidates board ~n ~windows ~roles:Roles.names ~role_of:(fun _ ->
        return (Some User_role.Role.Vault))
    in
    let expected = Board.candidates board ~n ~windows in
    print_s
      [%message
        ""
          (n : int)
          ~same:
            ([%equal: Address.t list]
               (List.map selected ~f:(fun r -> r.eth_address))
               (List.map expected ~f:(fun r -> r.eth_address))
             : bool)
          ~excluded:(List.length excluded : int)])
  |> fun d ->
  let%map () = d in
  [%expect
    {|
    ((n 1) (same true) (excluded 0))
    ((n 2) (same true) (excluded 0))
    ((n 3) (same true) (excluded 0))
    ((n 6) (same true) (excluded 0))
    |}]
;;

let%expect_test "an unknown role is rejected; unknown names are rejected" =
  print_s
    [%message
      ""
        ~unknown:(Roles.accepts ~roles:Roles.names None : bool)
        ~agent:(Roles.accepts ~roles:Roles.default (Some (Agent { user = vault })) : bool)
        ~other:(Roles.accepts ~roles:Roles.names (Some (Other "new")) : bool)];
  List.iter [ "vault"; "subAccount"; "hlp" ] ~f:(fun s ->
    print_s [%sexp (Command.Arg_type.parse Roles.arg_type s : string Or_error.t)]);
  [%expect
    {|
    ((unknown false) (agent false) (other false))
    (Ok vault)
    (Ok subAccount)
    (Error ("unknown role" hlp (expected (user agent vault subAccount missing))))
    |}];
  return ()
;;

let%expect_test "an unanswered role is dropped" =
  let%bind candidates, excluded =
    Roles.candidates
      (board ())
      ~n:2
      ~windows:[ Week ]
      ~roles:Roles.default
      ~role_of:(fun address ->
        return (if Address.equal address vault then None else Some User_role.Role.User))
  in
  print_s
    [%message
      ""
        ~candidates:
          (List.map candidates ~f:(fun (r : Board.Row.t) -> r.eth_address)
           : Address.t list)
        ~excluded:
          (List.map excluded ~f:(fun ((r : Board.Row.t), role) -> r.eth_address, role)
           : (Address.t * User_role.Role.t option) list)];
  [%expect
    {|
    ((candidates
      (0xf5d81a135f756ca16544e53c20fc20643ec3ad53
       0x399965e15d4e61ec3529cc98b7f7ebb93b733336))
     (excluded ((0x87f9cd15f5050a9283b8896300f7c8cf69ece2cf ()))))
    |}];
  return ()
;;
