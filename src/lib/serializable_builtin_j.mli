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

open Serializable_builtin_t

(** {1 Serializers for type number} *)

val write_number : Bi_outbuf.t -> number -> unit
val read_number : Yojson.Safe.lexer_state -> Lexing.lexbuf -> number

(** {1 Serializers for type uuid} *)

val write_uuid : Bi_outbuf.t -> uuid -> unit
val read_uuid : Yojson.Safe.lexer_state -> Lexing.lexbuf -> uuid

(** {1 Serializers for type shape} *)

val write_shape : (Bi_outbuf.t -> 'a -> unit) -> Bi_outbuf.t -> 'a shape -> unit
val read_shape : (Yojson.Safe.lexer_state -> Lexing.lexbuf -> 'a) -> Yojson.Safe.lexer_state -> Lexing.lexbuf -> 'a shape
