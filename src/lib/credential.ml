(**************************************************************************)
(*                                BELENIOS                                *)
(*                                                                        *)
(*  Copyright © 2012-2020 Inria                                           *)
(*                                                                        *)
(*  This program is free software: you can redistribute it and/or modify  *)
(*  it under the terms of the GNU Affero General Public License as        *)
(*  published by the Free Software Foundation, either version 3 of the    *)
(*  License, or (at your option) any later version, with the additional   *)
(*  exemption that compiling, linking, and/or using OpenSSL is allowed.   *)
(*                                                                        *)
(*  This program is distributed in the hope that it will be useful, but   *)
(*  WITHOUT ANY WARRANTY; without even the implied warranty of            *)
(*  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU     *)
(*  Affero General Public License for more details.                       *)
(*                                                                        *)
(*  You should have received a copy of the GNU Affero General Public      *)
(*  License along with this program.  If not, see                         *)
(*  <http://www.gnu.org/licenses/>.                                       *)
(**************************************************************************)

open Belenios_platform
open Serializable_builtin_t
open Platform
open Signatures

let digits = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
let token_length = 14
let n58 = Z.of_int 58
let n53 = Z.of_int 53

module MakeGenerate (M : RANDOM) = struct

  let get_random_digit () =
    M.bind (M.random n58) (fun x -> M.return (Z.to_int x))

  let generate_raw_token () =
    let res = Bytes.create token_length in
    let rec loop i accu =
      if i < token_length then (
        M.bind (get_random_digit ()) (fun digit ->
          Bytes.set res i digits.[digit];
          loop (i+1) Z.(n58 * accu + of_int digit)
        )
      ) else M.return (Bytes.to_string res, accu)
    in loop 0 Z.zero

  let add_checksum (raw, value) =
    let checksum = 53 - Z.(to_int (value mod n53)) in
    M.return (raw ^ String.make 1 digits.[checksum])

  let generate () =
    M.bind (generate_raw_token ()) add_checksum

end

let check x =
  String.length x = token_length + 1 &&
  let rec loop i accu =
    if i < token_length then
      match String.index_opt digits x.[i] with
      | Some digit -> loop (i+1) Z.(n58 * accu + of_int digit)
      | None -> None
    else Some accu
  in
  match loop 0 Z.zero, String.index_opt digits x.[token_length] with
  | Some n, Some checksum -> Z.((n + of_int checksum) mod n53 =% zero)
  | _, _ -> false

module MakeDerive (G : GROUP) = struct

  let derive uuid x =
    let uuid = raw_string_of_uuid uuid in
    let derived = pbkdf2_utf8 ~iterations:1000 ~salt:uuid x in
    Z.(of_hex derived mod G.q)

end
