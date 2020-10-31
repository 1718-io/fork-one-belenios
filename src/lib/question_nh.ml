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
open Platform
open Common
open Signatures_core
open Serializable_builtin_t
open Serializable_core_t
open Question_nh_t

module Make (M : RANDOM) (G : GROUP) = struct
  let ( >>= ) = M.bind
  open G

  let create_answer q ~public_key:y ~prefix m =
    assert (Array.length q.q_answers = Array.length m);
    M.random G.q >>= fun r ->
    let alpha = g **~ r and beta = (y **~ r) *~ (G.of_ints m) in
    M.random G.q >>= fun w ->
    let commitment = g **~ w in
    let zkp = Printf.sprintf "raweg|%s|%s,%s,%s|" prefix (G.to_string y) (G.to_string alpha) (G.to_string beta) in
    let challenge = G.hash zkp [| commitment |] in
    let response = Z.(erem (w - r * challenge) G.q) in
    let proof = {challenge; response} in
    let choices = {alpha; beta} in
    M.return {choices; proof}

  let verify_answer _ ~public_key:y ~prefix a =
    let {alpha; beta} = a.choices in
    let {challenge; response} = a.proof in
    G.check alpha && G.check beta &&
    check_modulo G.q challenge && check_modulo G.q response &&
    let commitment = (g **~ response) *~ (alpha **~ challenge) in
    let zkp = Printf.sprintf "raweg|%s|%s,%s,%s|" prefix (G.to_string y) (G.to_string alpha) (G.to_string beta) in
    Z.(challenge =% G.hash zkp [| commitment |])

  let extract_ciphertexts _ a =
    SAtomic a.choices

  let compare_ciphertexts x y =
    match x, y with
    | SAtomic x, SAtomic y ->
       let c = G.compare x.alpha y.alpha in
       if c = 0 then G.compare x.beta y.beta else c
    | _, _ -> invalid_arg "Question_nh.compare_ciphertexts"

  let process_ciphertexts _ es =
    Array.fast_sort compare_ciphertexts es;
    SArray es

  let compute_result ~num_tallied:_ q x =
    let n = Array.length q.q_answers in
    let rec aux = function
      | SAtomic x -> SArray (Array.map (fun x -> SAtomic x) (G.to_ints n x))
      | SArray xs -> SArray (Array.map aux xs)
    in aux x

  let check_result q x r =
    r = compute_result ~num_tallied:0 q x
end
