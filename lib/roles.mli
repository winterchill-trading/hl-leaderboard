(** Account roles ([userRole], {!Hl_protocol.User_role}) in candidate selection.

    The leaderboard lists every kind of account: vaults (HLP among them), sub-accounts and
    API wallets next to ordinary traders. A follower can only copy an ordinary account in
    a meaningful way (a vault's trades are a strategy's, a sub-account is one leg of a
    bigger book), so by default only ["user"] rows become candidates. *)

open! Core
open! Async
open Hl_protocol

(** The wire names: ["user"], ["agent"], ["vault"], ["subAccount"], ["missing"]. *)
val names : string list

(** [["user"]] *)
val default : string list

(** One of {!names}. *)
val arg_type : string Command.Arg_type.t

(** Whether a role is in [roles] (wire names). An unknown role ([None]: the request failed
    after its retries) is never accepted, on any network: a vault must not slip in through
    a failed request. *)
val accepts : roles:string list -> User_role.Role.t option -> bool

(** Like {!Board.candidates}, but a row whose role is not accepted does not count towards
    a window's [n]: the walk goes down that window's ranking until [n] accepted rows (or
    the end). [role_of] is called at most once per address, only for rows the walk
    reaches. Returns the candidates in order of first appearance and the rows left out,
    with their role ([None] when the lookup failed). *)
val candidates
  :  ?min_account_value:float
  -> Board.t
  -> n:int
  -> windows:Board.Window.t list
  -> roles:string list
  -> role_of:(Address.t -> User_role.Role.t option Deferred.t)
  -> (Board.Row.t list * (Board.Row.t * User_role.Role.t option) list) Deferred.t
