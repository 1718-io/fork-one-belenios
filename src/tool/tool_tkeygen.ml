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
open Belenios
open Platform
open Serializable_j
open Signatures
open Common

module type PARAMS = sig
  val group : string
end

module type S = sig
  type keypair = { id : string; priv : string; pub : string }
  val trustee_keygen : unit -> keypair
end

module type PARSED_PARAMS = sig
  module G : GROUP
end

let parse_params p =
  let module P = (val p : PARAMS) in
  let module R = struct
    module G = (val Group.of_string P.group : GROUP)
  end
  in (module R : PARSED_PARAMS)

module Make (P : PARSED_PARAMS) : S = struct
  open P

  (* Generate key *)

  module KG = Trustees.MakeSimple (G) (DirectRandom)
  module K = Trustees.MakeCombinator (G)

  type keypair = { id : string; priv : string; pub : string }

  let trustee_keygen () =
    let private_key = KG.generate () in
    let public_key = KG.prove private_key in
    assert (K.check [`Single public_key]);
    let id = String.sub
      (sha256_hex (G.to_string public_key.trustee_public_key))
      0 8 |> String.uppercase_ascii
    in
    let priv = string_of_number private_key in
    let pub = string_of_trustee_public_key G.write public_key in
    {id; priv; pub}

end

let make params =
  let module P = (val parse_params params : PARSED_PARAMS) in
  let module R = Make (P) in
  (module R : S)
