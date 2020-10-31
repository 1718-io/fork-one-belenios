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

open Lwt
open Belenios
open Serializable_builtin_t
open Serializable_j
open Signatures
open Common
open Web_serializable_builtin_t
open Web_serializable_j
open Web_common
open Web_services
open Site_common

let ( / ) = Filename.concat

module PString = String

open Eliom_service
open Eliom_registration

let get_preferred_gettext () = Web_i18n.get_preferred_gettext "admin"

let dump_passwords uuid db =
  List.map (fun line -> PString.concat "," line) db |>
    write_file ~uuid "passwords.csv"

let validate_election uuid se =
  let uuid_s = raw_string_of_uuid uuid in
  (* voters *)
  let () =
    if se.se_voters = [] then failwith "no voters"
  in
  (* passwords *)
  let () =
    match se.se_metadata.e_auth_config with
    | Some [{auth_system = "password"; _}] ->
       if not @@ List.for_all (fun v -> v.sv_password <> None) se.se_voters then
         failwith "some passwords are missing"
    | _ -> ()
  in
  (* credentials *)
  let () =
    if not se.se_public_creds_received then
      failwith "public credentials are missing"
  in
  (* trustees *)
  let group = Group.of_string se.se_group in
  let module G = (val group : GROUP) in
  let module K = Trustees.MakeCombinator (G) in
  let module KG = Trustees.MakeSimple (G) (LwtRandom) in
  let%lwt trustee_names, trustees, private_keys =
    match se.se_threshold_trustees with
    | None ->
       let%lwt trustee_names, trustees, private_key =
         match se.se_public_keys with
         | [] ->
            let%lwt private_key = KG.generate () in
            let%lwt public_key = KG.prove private_key in
            let public_key = { public_key with trustee_name = Some "server" } in
            return (["server"], [`Single public_key], `KEY private_key)
         | _ :: _ ->
            let private_key =
              List.fold_left (fun accu {st_private_key; _} ->
                  match st_private_key with
                  | Some x -> x :: accu
                  | None -> accu
                ) [] se.se_public_keys
            in
            let private_key = match private_key with
              | [] -> `None
              | [x] -> `KEY x
              | _ -> failwith "multiple private keys"
            in
            return (
                (List.map (fun {st_id; _} -> st_id) se.se_public_keys),
                (List.map
                   (fun {st_public_key; st_name; _} ->
                     if st_public_key = "" then failwith "some public keys are missing";
                     let pk = trustee_public_key_of_string G.read st_public_key in
                     let pk = { pk with trustee_name = st_name } in
                     `Single pk
                   ) se.se_public_keys),
                private_key)
       in
       return (trustee_names, trustees, private_key)
    | Some ts ->
       match se.se_threshold_parameters with
       | None -> failwith "key establishment not finished"
       | Some tp ->
          let tp = threshold_parameters_of_string G.read tp in
          let named =
            List.combine (Array.to_list tp.t_verification_keys) ts
            |> List.map (fun (k, t) -> { k with trustee_name = t.stt_name })
            |> Array.of_list
          in
          let tp = { tp with t_verification_keys = named } in
          let trustee_names = List.map (fun {stt_id; _} -> stt_id) ts in
          let private_keys =
            List.map (fun {stt_voutput; _} ->
                match stt_voutput with
                | Some v ->
                   let voutput = voutput_of_string G.read v in
                   voutput.vo_private_key
                | None -> failwith "inconsistent state"
              ) ts
          in
          let%lwt server_private_key = KG.generate () in
          let%lwt server_public_key = KG.prove server_private_key in
          let server_public_key = { server_public_key with trustee_name = Some "server" } in
          return (
              "server" :: trustee_names,
              [`Single server_public_key; `Pedersen tp],
              `KEYS (server_private_key, private_keys)
            )
  in
  let y = K.combine_keys trustees in
  (* election parameters *)
  let e_server_is_trustee = match private_keys with
      | `KEY _ | `KEYS _ -> Some true
      | `None -> None
  in
  let metadata = {
      se.se_metadata with
      e_trustees = Some trustee_names;
      e_server_is_trustee;
    } in
  let template = se.se_questions in
  let params = {
    e_description = template.t_description;
    e_name = template.t_name;
    e_public_key = {wpk_group = G.group; wpk_y = y};
    e_questions = template.t_questions;
    e_uuid = uuid;
    e_administrator = se.se_administrator;
    e_credential_authority = metadata.e_cred_authority;
  } in
  let raw_election = string_of_params (write_wrapped_pubkey G.write_group G.write) params in
  (* write election files to disk *)
  let dir = !Web_config.spool_dir / uuid_s in
  let create_file fname what xs =
    Lwt_io.with_file
      ~flags:(Unix.([O_WRONLY; O_NONBLOCK; O_CREAT; O_TRUNC]))
      ~perm:0o600 ~mode:Lwt_io.Output (dir / fname)
      (fun oc ->
        Lwt_list.iter_s
          (fun v ->
            let%lwt () = Lwt_io.write oc (what v) in
            Lwt_io.write oc "\n") xs)
  in
  let%lwt () = create_file "trustees.json" (string_of_trustees G.write) [trustees] in
  let%lwt () = create_file "voters.txt" (fun x -> x.sv_id) se.se_voters in
  let%lwt () = create_file "metadata.json" string_of_metadata [metadata] in
  let%lwt () = create_file "election.json" (fun x -> x) [raw_election] in
  let%lwt () = create_file "ballots.jsons" (fun x -> x) [] in
  (* initialize credentials *)
  let%lwt () =
    let fname = !Web_config.spool_dir / uuid_s / "public_creds.txt" in
    match%lwt read_file fname with
    | Some xs -> Web_persist.init_credential_mapping uuid xs
    | None -> return_unit
  in
  (* create file with private keys, if any *)
  let%lwt () =
    match private_keys with
    | `None -> return_unit
    | `KEY x -> create_file "private_key.json" string_of_number [x]
    | `KEYS (x, y) ->
       create_file "private_key.json" string_of_number [x];%lwt
       create_file "private_keys.jsons" (fun x -> x) y
  in
  (* clean up draft *)
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "draft.json") in
  (* clean up private credentials, if any *)
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "private_creds.txt") in
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "private_creds.downloaded") in
  (* write passwords *)
  let%lwt () =
    match metadata.e_auth_config with
    | Some [{auth_system = "password"; _}] ->
       let db =
         List.filter_map (fun v ->
             let _, login = split_identity v.sv_id in
             match v.sv_password with
             | Some (salt, hashed) -> Some [login; salt; hashed]
             | None -> None
           ) se.se_voters
       in
       if db <> [] then dump_passwords uuid db else return_unit
    | _ -> return_unit
  in
  (* finish *)
  let%lwt () = Web_persist.set_election_state uuid `Open in
  let%lwt dates = Web_persist.get_election_dates uuid in
  Web_persist.set_election_dates uuid {dates with e_finalization = Some (now ())}

let delete_sensitive_data uuid =
  let uuid_s = raw_string_of_uuid uuid in
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "state.json") in
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "decryption_tokens.json") in
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "partial_decryptions.json") in
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "extended_records.jsons") in
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "credential_mappings.jsons") in
  let%lwt () = rmdir (!Web_config.spool_dir / uuid_s / "ballots") in
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "private_key.json") in
  let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "private_keys.jsons") in
  return_unit

let archive_election uuid =
  let%lwt () = delete_sensitive_data uuid in
  let%lwt dates = Web_persist.get_election_dates uuid in
  Web_persist.set_election_dates uuid {dates with e_archive = Some (now ())}

let delete_election uuid =
  let uuid_s = raw_string_of_uuid uuid in
  let%lwt () = delete_sensitive_data uuid in
  match%lwt find_election uuid with
  | None -> return_unit
  | Some election ->
  let%lwt metadata = Web_persist.get_election_metadata uuid in
  let de_template = {
      t_description = "";
      t_name = election.e_params.e_name;
      t_questions = Array.map Question.erase_question election.e_params.e_questions;
      t_administrator = None;
      t_credential_authority = None;
    }
  in
  let de_owner = match metadata.e_owner with
    | None -> Printf.ksprintf failwith "election %s has no owner" uuid_s
    | Some x -> x
  in
  let%lwt dates = Web_persist.get_election_dates uuid in
  let de_date =
    match dates.e_tally with
    | Some x -> x
    | None ->
       match dates.e_finalization with
       | Some x -> x
       | None ->
          match dates.e_creation with
          | Some x -> x
          | None -> default_validation_date
  in
  let de_authentication_method = match metadata.e_auth_config with
    | Some [{auth_system = "cas"; auth_config; _}] ->
       let server = List.assoc "server" auth_config in
       `CAS server
    | Some [{auth_system = "password"; _}] -> `Password
    | _ -> `Unknown
  in
  let de_credential_method = match metadata.e_cred_authority with
    | Some "server" -> `Automatic
    | _ -> `Manual
  in
  let%lwt de_trustees =
    let%lwt trustees = Web_persist.get_trustees uuid in
    trustees_of_string Yojson.Safe.read_json trustees
    |> List.map
         (function
          | `Single _ -> `Single
          | `Pedersen t -> `Pedersen (t.t_threshold, Array.length t.t_verification_keys)
         )
    |> return
  in
  let%lwt voters = Web_persist.get_voters uuid in
  let%lwt ballots = Web_persist.get_ballot_hashes uuid in
  let%lwt result = Web_persist.get_election_result uuid in
  let de = {
      de_uuid = uuid;
      de_template;
      de_owner;
      de_nb_voters = (match voters with None -> 0 | Some x -> List.length x);
      de_nb_ballots = List.length ballots;
      de_date;
      de_tallied = result <> None;
      de_authentication_method;
      de_credential_method;
      de_trustees;
      de_server_is_trustee = metadata.e_server_is_trustee = Some true;
    }
  in
  let%lwt () = write_file ~uuid "deleted.json" [string_of_deleted_election de] in
  let files_to_delete = [
      "election.json";
      "ballots.jsons";
      "dates.json";
      "encrypted_tally.json";
      "metadata.json";
      "passwords.csv";
      "public_creds.txt";
      "trustees.json";
      "records";
      "result.json";
      "hide_result";
      "shuffle_token";
      "shuffles.jsons";
      "voters.txt";
      "archive.zip";
      "audit_cache.json";
    ]
  in
  let%lwt () = Lwt_list.iter_p (fun x ->
                   cleanup_file (!Web_config.spool_dir / uuid_s / x)
                 ) files_to_delete
  in
  return_unit

let () = Any.register ~service:home
  (fun () () -> Redirection.send (Redirection admin))

let get_elections_by_owner_sorted u =
  let%lwt elections = Web_persist.get_elections_by_owner u in
  let filter kind =
    List.filter (fun (x, _, _, _) -> x = kind) elections |>
    List.map (fun (_, a, b, c) -> a, b, c)
  in
  let draft = filter `Draft in
  let elections = filter `Validated in
  let tallied = filter `Tallied in
  let archived = filter `Archived in
  let sort l =
    List.sort (fun (_, x, _) (_, y, _) -> datetime_compare x y) l |>
    List.map (fun (x, _, y) -> x, y)
  in
  return (sort draft, sort elections, sort tallied, sort archived)

let with_site_user f =
  match%lwt Eliom_reference.get Web_state.site_user with
  | Some u -> f u
  | None -> forbidden ()

let without_site_user ?fallback f =
  let%lwt l = get_preferred_gettext () in
  let open (val l) in
  match%lwt Eliom_reference.get Web_state.site_user with
  | None -> f ()
  | Some u ->
     match fallback with
     | Some g -> g u
     | None ->
        Pages_common.generic_page ~title:(s_ "Error")
          (s_ "This page is not accessible to authenticated administrators, because it is meant to be used by third parties.")
          () >>= Html.send

let () =
  Redirection.register ~service:privacy_notice_accept
    (fun cont () ->
      let%lwt () = Eliom_reference.set Web_state.show_cookie_disclaimer false in
      let cont = match cont with
        | ContAdmin -> Redirection admin
        | ContSignup service -> Redirection (preapply ~service:signup_captcha service)
      in
      return cont
    )

let () = Html.register ~service:admin
  (fun () () ->
    let%lwt gdpr = Eliom_reference.get Web_state.show_cookie_disclaimer in
    if gdpr then Pages_admin.privacy_notice ContAdmin else
    let%lwt site_user = Eliom_reference.get Web_state.site_user in
    let%lwt elections =
      match site_user with
      | None -> return_none
      | Some u ->
         let%lwt elections = get_elections_by_owner_sorted u in
         return_some elections
    in
    Pages_admin.admin ~elections ()
  )

let generate_uuid () =
  let length = !Web_config.uuid_length in
  let%lwt token = generate_token ?length () in
  return (uuid_of_raw_string token)

let create_new_election owner cred auth =
  let e_cred_authority = match cred with
    | `Automatic -> Some "server"
    | `Manual -> None
  in
  let e_auth_config = match auth with
    | `Password -> Some [{auth_system = "password"; auth_instance = "password"; auth_config = []}]
    | `Dummy -> Some [{auth_system = "dummy"; auth_instance = "dummy"; auth_config = []}]
    | `CAS server -> Some [{auth_system = "cas"; auth_instance = "cas"; auth_config = ["server", server]}]
  in
  let%lwt uuid = generate_uuid () in
  let%lwt token = generate_token () in
  let se_metadata = {
    e_owner = Some owner;
    e_auth_config;
    e_cred_authority;
    e_trustees = None;
    e_languages = Some ["en"; "fr"];
    e_contact = None;
    e_server_is_trustee = None;
  } in
  let se_questions = {
    t_description = default_description;
    t_name = default_name;
    t_questions = default_questions;
    t_administrator = None;
    t_credential_authority = None;
  } in
  let se = {
    se_owner = owner;
    se_group = !Web_config.default_group;
    se_voters = [];
    se_questions;
    se_public_keys = [];
    se_metadata;
    se_public_creds = token;
    se_public_creds_received = false;
    se_threshold = None;
    se_threshold_trustees = None;
    se_threshold_parameters = None;
    se_threshold_error = None;
    se_creation_date = Some (now ());
    se_administrator = None;
  } in
  let%lwt () = Lwt_unix.mkdir (!Web_config.spool_dir / raw_string_of_uuid uuid) 0o700 in
  let%lwt () = Web_persist.set_draft_election uuid se in
  redir_preapply election_draft uuid ()

let () = Html.register ~service:election_draft_pre
  (fun () () -> Pages_admin.election_draft_pre ())

let http_rex = "^https?://[a-z0-9/.-]+$"

let is_http_url =
  let rex = Pcre.regexp ~flags:[`CASELESS] http_rex in
  fun x ->
  match pcre_exec_opt ~rex x with
  | Some _ -> true
  | None -> false

let () = Any.register ~service:election_draft_new
  (fun () (credmgmt, (auth, cas_server)) ->
    let%lwt l = get_preferred_gettext () in
    let open (val l) in
    with_site_user (fun u ->
        let%lwt credmgmt = match credmgmt with
          | Some "auto" -> return `Automatic
          | Some "manual" -> return `Manual
          | _ -> fail_http 400
        in
        let%lwt auth = match auth with
          | Some "password" -> return `Password
          | Some "dummy" -> return `Dummy
          | Some "cas" -> return @@ `CAS (PString.trim cas_server)
          | _ -> fail_http 400
        in
        match auth with
        | `CAS cas_server when not (is_http_url cas_server) ->
           Pages_common.generic_page ~title:(s_ "Error") (s_ "Bad CAS server!") () >>= Html.send
        | _ -> create_new_election u credmgmt auth
      )
  )

let with_draft_election_ro uuid f =
  with_site_user (fun u ->
      match%lwt Web_persist.get_draft_election uuid with
      | None -> fail_http 404
      | Some se -> if se.se_owner = u then f se else forbidden ()
    )

let () =
  Html.register ~service:election_draft
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          Pages_admin.election_draft uuid se ()
        )
    )

let () =
  Any.register ~service:election_draft_trustees
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          match se.se_threshold_trustees with
          | None -> Pages_admin.election_draft_trustees uuid se () >>= Html.send
          | Some _ -> redir_preapply election_draft_threshold_trustees uuid ()
        )
    )

let () =
  Html.register ~service:election_draft_threshold_trustees
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          Pages_admin.election_draft_threshold_trustees uuid se ()
        )
    )

let () =
  Html.register ~service:election_draft_credential_authority
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          Pages_admin.election_draft_credential_authority uuid se ()
        )
    )

let with_draft_election ?(save = true) uuid f =
  with_site_user (fun u ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      Web_election_mutex.with_lock uuid (fun () ->
          match%lwt Web_persist.get_draft_election uuid with
          | None -> fail_http 404
          | Some se ->
             if se.se_owner = u then (
               match%lwt f se with
               | r ->
                  let%lwt () = if save then Web_persist.set_draft_election uuid se else return_unit in
                  return r
               | exception e ->
                  let msg = match e with Failure s -> s | _ -> Printexc.to_string e in
                  let service = preapply ~service:election_draft uuid in
                  Pages_common.generic_page ~title:(s_ "Error") ~service msg () >>= Html.send
             ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_draft_set_credential_authority
    (fun uuid name ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let service = Eliom_service.preapply ~service:election_draft_credential_authority uuid in
          match (
            if se.se_metadata.e_cred_authority = Some "server" then
              Error (s_ "You cannot set the credential authority for this election!")
            else
              match name with
              | "" -> Ok None
              | "server" -> Error (s_ "Invalid public name for credential authority!")
              | x -> Ok (Some x)
          ) with
          | Ok e_cred_authority ->
             se.se_metadata <- {se.se_metadata with e_cred_authority};
             let msg = s_ "The public name of the credential authority has been set successfully!" in
             Pages_common.generic_page ~title:(s_ "Success") ~service msg () >>= Html.send
          | Error msg ->
             Pages_common.generic_page ~title:(s_ "Error") ~service msg () >>= Html.send
        )
    )

let () =
  Any.register ~service:election_draft_languages
    (fun uuid languages ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let langs = languages_of_string languages in
          match langs with
          | [] ->
             let service = preapply ~service:election_draft uuid in
             Pages_common.generic_page ~title:(s_ "Error") ~service
               (s_ "You must select at least one language!") () >>= Html.send
          | _ :: _ ->
             let unavailable =
               List.filter (fun x ->
                   not (List.mem x available_languages)
                 ) langs
             in
             match unavailable with
             | [] ->
                se.se_metadata <- {
                   se.se_metadata with
                   e_languages = Some langs
                 };
                redir_preapply election_draft uuid ()
             | l :: _ ->
                let service = preapply ~service:election_draft uuid in
                Pages_common.generic_page ~title:(s_ "Error") ~service
                  (Printf.sprintf (f_ "No such language: %s") l) () >>= Html.send
        )
    )

let () =
  Any.register ~service:election_draft_contact
    (fun uuid contact ->
      with_draft_election uuid (fun se ->
          let contact =
            if contact = "" || contact = default_contact then
              None
            else Some contact
          in
          se.se_metadata <- {
              se.se_metadata with
              e_contact = contact
            };
          redir_preapply election_draft uuid ()
        )
    )

let () =
  Any.register ~service:election_draft_admin_name
    (fun uuid name ->
      with_draft_election uuid (fun se ->
          let administrator = if name = "" then None else Some name in
          se.se_administrator <- administrator;
          redir_preapply election_draft uuid ()
        )
    )

let () =
  Any.register ~service:election_draft_description
    (fun uuid (name, description) ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          if PString.length name > max_election_name_size then (
            let msg =
              Printf.sprintf (f_ "The election name must be %d characters or less!")
                max_election_name_size
            in
            Pages_common.generic_page ~title:(s_ "Error") msg () >>= Html.send
          ) else (
            se.se_questions <- {se.se_questions with
                                 t_name = name;
                                 t_description = description;
                               };
            redir_preapply election_draft uuid ()
          )
        )
    )

let handle_password se uuid ~force voters =
  let%lwt l = get_preferred_gettext () in
  let open (val l) in
  if List.length voters > !Web_config.maxmailsatonce then
    Lwt.fail (Failure (Printf.sprintf (f_ "Cannot send passwords, there are too many voters (max is %d)") !Web_config.maxmailsatonce))
  else if se.se_questions.t_name = default_name then
    Lwt.fail (Failure (s_ "The election name has not been edited!"))
  else
  let title = se.se_questions.t_name in
  let url = Eliom_uri.make_string_uri ~absolute:true ~service:election_home
    (uuid, ()) |> rewrite_prefix
  in
  let langs = get_languages se.se_metadata.e_languages in
  let%lwt () =
    Lwt_list.iter_s (fun id ->
        match id.sv_password with
        | Some _ when not force -> return_unit
        | None | Some _ ->
           let%lwt x = Pages_voter.generate_password se.se_metadata langs title url id.sv_id in
           return (id.sv_password <- Some x)
      ) voters
  in
  let service = preapply ~service:election_draft uuid in
  Pages_common.generic_page ~title:(s_ "Success") ~service
    (s_ "Passwords have been generated and mailed!") () >>= Html.send

let () =
  Any.register ~service:election_draft_auth_genpwd
    (fun uuid () ->
      with_draft_election uuid (fun se ->
          handle_password se uuid ~force:false se.se_voters
        )
    )

let () =
  Any.register ~service:election_regenpwd
    (fun uuid () ->
      Pages_admin.regenpwd uuid () >>= Html.send)

let find_user_id uuid user =
  let uuid_s = raw_string_of_uuid uuid in
  let db = Lwt_io.lines_of_file (!Web_config.spool_dir / uuid_s / "voters.txt") in
  let%lwt db = Lwt_stream.to_list db in
  let rec loop = function
    | [] -> None
    | id :: xs ->
       let _, login = split_identity id in
       if login = user then Some id else loop xs
  in return (loop db)

let load_password_db uuid =
  let uuid_s = raw_string_of_uuid uuid in
  let db = !Web_config.spool_dir / uuid_s / "passwords.csv" in
  Lwt_preemptive.detach Csv.load db

let rec replace_password username ((salt, hashed) as p) = function
  | [] -> []
  | ((username' :: _ :: _ :: rest) as x) :: xs ->
     if username = username' then (username :: salt :: hashed :: rest) :: xs
     else x :: (replace_password username p xs)
  | x :: xs -> x :: (replace_password username p xs)

let () =
  Any.register ~service:election_regenpwd_post
    (fun uuid user ->
      with_site_user (fun u ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          match%lwt find_election uuid with
          | None -> election_not_found ()
          | Some election ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          if metadata.e_owner = Some u then (
            let title = election.e_params.e_name in
            let url = Eliom_uri.make_string_uri
                        ~absolute:true ~service:election_home
                        (uuid, ()) |> rewrite_prefix
            in
            let service = preapply ~service:election_admin uuid in
            match%lwt find_user_id uuid user with
            | Some id ->
               let langs = get_languages metadata.e_languages in
               let%lwt db = load_password_db uuid in
               let%lwt x = Pages_voter.generate_password metadata langs title url id in
               let db = replace_password user x db in
               let%lwt () = dump_passwords uuid db in
               Pages_common.generic_page ~title:(s_ "Success") ~service
                 (Printf.sprintf (f_ "A new password has been mailed to %s.") id) ()
               >>= Html.send
            | None ->
               Pages_common.generic_page ~title:(s_ "Error") ~service
                 (Printf.sprintf (f_ "%s is not a registered user for this election.") user) ()
               >>= Html.send
          ) else forbidden ()
        )
    )

let () =
  Html.register ~service:election_draft_questions
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          Pages_admin.election_draft_questions uuid se ()
        )
    )

let () =
  Any.register ~service:election_draft_questions_post
    (fun uuid template ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let template = template_of_string template in
          let fixed_group = is_group_fixed se in
          (match get_suitable_group_kind se.se_questions, get_suitable_group_kind template with
           | `NH, `NH | `H, `H -> ()
           | `NH, `H when fixed_group -> ()
           | `NH, `H -> se.se_group <- !Web_config.default_group
           | `H, `NH when fixed_group -> failwith (s_ "This kind of change is not allowed now!")
           | `H, `NH -> se.se_group <- !Web_config.nh_group
          );
          se.se_questions <- template;
          redir_preapply election_draft uuid ()
        )
    )

let () =
  Any.register ~service:election_draft_preview
    (fun (uuid, ()) () ->
      with_draft_election_ro uuid (fun se ->
          let group = Group.of_string se.se_group in
          let module G = (val group : GROUP) in
          let params = {
              e_description = se.se_questions.t_description;
              e_name = se.se_questions.t_name;
              e_public_key = {wpk_group = G.group; wpk_y = G.g};
              e_questions = se.se_questions.t_questions;
              e_uuid = uuid;
              e_administrator = se.se_administrator;
              e_credential_authority = se.se_metadata.e_cred_authority;
            } in
          String.send (string_of_params (write_wrapped_pubkey G.write_group G.write) params, "application/json")
        )
    )

let () =
  Html.register ~service:election_draft_voters
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          Pages_admin.election_draft_voters uuid se !Web_config.maxmailsatonce ()
        )
    )

(* see http://www.regular-expressions.info/email.html *)
let identity_rex = Pcre.regexp
  ~flags:[`CASELESS]
  "^[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}(,[A-Z0-9._%+-]+)?$"

let is_identity x =
  match pcre_exec_opt ~rex:identity_rex x with
  | Some _ -> true
  | None -> false

let merge_voters a b f =
  let existing = List.fold_left (fun accu sv ->
    SSet.add sv.sv_id accu
  ) SSet.empty a in
  let _, res = List.fold_left (fun (existing, accu) sv_id ->
    if SSet.mem sv_id existing then
      (existing, accu)
    else
      (SSet.add sv_id existing, {sv_id; sv_password = f sv_id} :: accu)
  ) (existing, List.rev a) b in
  List.rev res

let () =
  Any.register ~service:election_draft_voters_add
    (fun uuid voters ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          if se.se_public_creds_received then
            forbidden ()
          else (
            let voters = Pcre.split voters in
            let () =
              match List.find_opt (fun x -> not (is_identity x)) voters with
              | Some bad ->
                 Printf.ksprintf failwith (f_ "%S is not a valid identity") bad
              | None -> ()
            in
            let voters = merge_voters se.se_voters voters (fun _ -> None) in
            let uses_password_auth =
              match se.se_metadata.e_auth_config with
              | Some configs ->
                 List.exists
                   (fun {auth_system; _} -> auth_system = "password")
                   configs
              | None -> false
            in
            let cred_auth_is_server =
              se.se_metadata.e_cred_authority = Some "server"
            in
            if
              (uses_password_auth || cred_auth_is_server)
              && List.length voters > !Web_config.maxmailsatonce
            then
              Lwt.fail
                (Failure
                   (Printf.sprintf (f_ "There are too many voters (max is %d)")
                      !Web_config.maxmailsatonce))
            else (
              se.se_voters <- voters;
              redir_preapply election_draft_voters uuid ()
            )
          )
        )
    )

let () =
  Any.register ~service:election_draft_voters_remove
    (fun uuid voter ->
      with_draft_election uuid (fun se ->
          if se.se_public_creds_received then
            forbidden ()
          else (
            se.se_voters <- List.filter (fun v -> v.sv_id <> voter) se.se_voters;
            redir_preapply election_draft_voters uuid ()
          )
        )
    )

let () =
  Any.register ~service:election_draft_voters_remove_all
    (fun uuid () ->
      with_draft_election uuid (fun se ->
          if se.se_public_creds_received then
            forbidden ()
          else (
            se.se_voters <- [];
            redir_preapply election_draft_voters uuid ()
          )
        )
    )

let () =
  Any.register ~service:election_draft_voters_passwd
    (fun uuid voter ->
      with_draft_election uuid (fun se ->
          let voter = List.filter (fun v -> v.sv_id = voter) se.se_voters in
          handle_password se uuid ~force:true voter
        )
    )

let trustee_add_server se =
  let st_id = "server" and st_token = "" in
  let module G = (val Group.of_string se.se_group) in
  let module K = Trustees.MakeSimple (G) (LwtRandom) in
  let%lwt private_key = K.generate () in
  let%lwt public_key = K.prove private_key in
  let st_public_key = string_of_trustee_public_key G.write public_key in
  let st_private_key = Some private_key in
  let st_name = Some "server" in
  let trustee = {st_id; st_token; st_public_key; st_private_key; st_name} in
  se.se_public_keys <- se.se_public_keys @ [trustee];
  return_unit

let () =
  Any.register ~service:election_draft_trustee_add
    (fun uuid (st_id, name) ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let%lwt () =
            if List.exists (fun x -> x.st_id = "server") se.se_public_keys then
              return_unit
            else trustee_add_server se
          in
          if is_email st_id then (
            let%lwt st_token = generate_token () in
            let st_name = Some name in
            let trustee = {st_id; st_token; st_public_key = ""; st_private_key = None; st_name} in
            se.se_public_keys <- se.se_public_keys @ [trustee];
            redir_preapply election_draft_trustees uuid ()
          ) else (
            let msg = Printf.sprintf (f_ "%s is not a valid e-mail address!") st_id in
            let service = preapply ~service:election_draft_trustees uuid in
            Pages_common.generic_page ~title:(s_ "Error") ~service msg () >>= Html.send
          )
        )
    )

let () =
  Any.register ~service:election_draft_trustee_del
    (fun uuid index ->
      with_draft_election uuid (fun se ->
          let trustees =
            se.se_public_keys |>
              List.mapi (fun i x -> i, x) |>
              List.filter (fun (i, _) -> i <> index) |>
              List.map snd
          in
          se.se_public_keys <- trustees;
          redir_preapply election_draft_trustees uuid ()
        )
    )

let () =
  Any.register ~service:election_draft_credentials
    (fun (uuid, token) () ->
      without_site_user (fun () ->
          match%lwt Web_persist.get_draft_election uuid with
          | None -> fail_http 404
          | Some se -> Pages_admin.election_draft_credentials token uuid se () >>= Html.send
        )
    )

let handle_credentials_post uuid token creds =
  match%lwt Web_persist.get_draft_election uuid with
  | None -> fail_http 404
  | Some se ->
  if se.se_public_creds <> token then forbidden () else
  if se.se_public_creds_received then forbidden () else
  let module G = (val Group.of_string se.se_group : GROUP) in
  let fname = !Web_config.spool_dir / raw_string_of_uuid uuid / "public_creds.txt" in
  let%lwt () =
    Web_election_mutex.with_lock uuid
      (fun () ->
        Lwt_io.with_file
          ~flags:(Unix.([O_WRONLY; O_NONBLOCK; O_CREAT; O_TRUNC]))
          ~perm:0o600 ~mode:Lwt_io.Output fname
          (fun oc -> Lwt_io.write_chars oc creds)
      )
  in
  let%lwt () =
    let i = ref 1 in
    match%lwt read_file fname with
    | Some xs ->
       let () =
         List.iter (fun x ->
             try
               let x = G.of_string x in
               if not (G.check x) then raise Exit;
               incr i
             with _ ->
               Printf.ksprintf failwith "invalid credential at line %d" !i
           ) xs
       in
       write_file fname xs
    | None -> return_unit
  in
  let () = se.se_public_creds_received <- true in
  let%lwt () = Web_persist.set_draft_election uuid se in
  Pages_admin.election_draft_credentials_done se () >>= Html.send

let () =
  Any.register ~service:election_draft_credentials_post
    (fun (uuid, token) creds ->
      without_site_user (fun () ->
          let s = Lwt_stream.of_string creds in
          wrap_handler (fun () -> handle_credentials_post uuid token s)
        )
    )

let () =
  Any.register ~service:election_draft_credentials_post_file
    (fun (uuid, token) creds ->
      without_site_user (fun () ->
          let s = Lwt_io.chars_of_file creds.Ocsigen_extensions.tmp_filename in
          wrap_handler (fun () -> handle_credentials_post uuid token s)
        )
    )

module CG = Credential.MakeGenerate (LwtRandom)

let () =
  Any.register ~service:election_draft_credentials_server
    (fun uuid () ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let nvoters = List.length se.se_voters in
          if nvoters > !Web_config.maxmailsatonce then
            Lwt.fail (Failure (Printf.sprintf (f_ "Cannot send credentials, there are too many voters (max is %d)") !Web_config.maxmailsatonce))
          else if nvoters = 0 then
            Lwt.fail (Failure (s_ "No voters"))
          else if se.se_questions.t_name = default_name then
            Lwt.fail (Failure (s_ "The election name has not been edited!"))
          else if se.se_public_creds_received then
            forbidden ()
          else (
            let () = se.se_metadata <- {se.se_metadata with
                                         e_cred_authority = Some "server"
                                       } in
            let title = se.se_questions.t_name in
            let url = Eliom_uri.make_string_uri
                        ~absolute:true ~service:election_home
                        (uuid, ()) |> rewrite_prefix
            in
            let module G = (val Group.of_string se.se_group : GROUP) in
            let module CSet = Set.Make (G) in
            let module CD = Credential.MakeDerive (G) in
            let%lwt public_creds, private_creds =
              Lwt_list.fold_left_s (fun (public_creds, private_creds) v ->
                  let email, _ = split_identity v.sv_id in
                  let cas =
                    match se.se_metadata.e_auth_config with
                    | Some [{auth_system = "cas"; _}] -> true
                    | _ -> false
                  in
                  let%lwt cred = CG.generate () in
                  let pub_cred =
                    let x = CD.derive uuid cred in
                    G.(g **~ x)
                  in
                  let langs = get_languages se.se_metadata.e_languages in
                  let%lwt bodies =
                    Lwt_list.map_s
                      (fun lang ->
                        let%lwt l = Web_i18n.get_lang_gettext "voter" lang in
                        return (Pages_voter.mail_credential l title cas cred url se.se_metadata)
                      ) langs
                  in
                  let body = PString.concat "\n\n----------\n\n" bodies in
                  let body = body ^ "\n\n-- \nBelenios" in
                  let%lwt subject =
                    let%lwt l = Web_i18n.get_lang_gettext "voter" (List.hd langs) in
                    let open (val l) in
                    Printf.ksprintf return (f_ "Your credential for election %s") title
                  in
                  let%lwt () = send_email email subject body in
                  return (CSet.add pub_cred public_creds, (v.sv_id, cred) :: private_creds)
                ) (CSet.empty, []) se.se_voters
            in
            let private_creds = List.rev_map (fun (id, c) -> id ^ " " ^ c) private_creds in
            let%lwt () = write_file ~uuid "private_creds.txt" private_creds in
            let public_creds = CSet.elements public_creds |> List.map G.to_string in
            let fname = !Web_config.spool_dir / raw_string_of_uuid uuid / "public_creds.txt" in
            let%lwt () =
              Lwt_io.with_file
                ~flags:(Unix.([O_WRONLY; O_NONBLOCK; O_CREAT; O_TRUNC]))
                ~perm:0o600 ~mode:Lwt_io.Output fname
                (fun oc ->
                  Lwt_list.iter_s (Lwt_io.write_line oc) public_creds)
            in
            se.se_public_creds_received <- true;
            let service = preapply ~service:election_draft uuid in
            Pages_common.generic_page ~title:(s_ "Success") ~service
              (s_ "Credentials have been generated and mailed! You should download private credentials (and store them securely), in case someone loses his/her credential.") () >>= Html.send
          )
        )
    )

let () =
  Any.register ~service:election_draft_credentials_get
    (fun uuid () ->
      with_draft_election_ro uuid
        (fun _ ->
          let%lwt () = write_file ~uuid "private_creds.downloaded" [] in
          File.send ~content_type:"text/plain"
            (!Web_config.spool_dir / raw_string_of_uuid uuid / "private_creds.txt")
        )
    )

let () =
  Any.register ~service:election_draft_trustee
    (fun (uuid, token) () ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      without_site_user
        ~fallback:(fun u ->
          match%lwt Web_persist.get_draft_election uuid with
          | None -> fail_http 404
          | Some se ->
             if se.se_owner = u then (
               Pages_admin.election_draft_trustees ~token uuid se () >>= Html.send
             ) else forbidden ()
        )
        (fun () ->
          match%lwt Web_persist.get_draft_election uuid with
          | None -> fail_http 404
          | Some se ->
             match List.find_opt (fun t -> t.st_token = token) se.se_public_keys with
             | None -> forbidden ()
             | Some t ->
                if t.st_public_key <> "" then
                  let msg = s_ "Your public key has already been received!" in
                  let title = s_ "Error" in
                  Pages_common.generic_page ~title msg () >>= Html.send ~code:403
                else
                  Pages_admin.election_draft_trustee token uuid se () >>= Html.send
        )
    )

let () =
  Any.register ~service:election_draft_trustee_post
    (fun (uuid, token) public_key ->
      without_site_user (fun () ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          if token = "" then
            forbidden ()
          else
            let%lwt title, msg, code =
              Web_election_mutex.with_lock uuid
                (fun () ->
                  match%lwt Web_persist.get_draft_election uuid with
                  | None -> fail_http 404
                  | Some se ->
                     match List.find_opt (fun x -> token = x.st_token) se.se_public_keys with
                     | None -> forbidden ()
                     | Some t ->
                        if t.st_public_key <> "" then
                          let msg = s_ "A public key already existed, the key you've just uploaded has been ignored!" in
                          let title = s_ "Error" in
                          return (title, msg, 400)
                        else
                          let module G = (val Group.of_string se.se_group : GROUP) in
                          let pk = trustee_public_key_of_string G.read public_key in
                          let module K = Trustees.MakeCombinator (G) in
                          if not (K.check [`Single pk]) then
                            let msg = s_ "Invalid public key!" in
                            let title = s_ "Error" in
                            return (title, msg, 400)
                          else (
                            (* we keep pk as a string because of G.t *)
                            t.st_public_key <- public_key;
                            let%lwt () = Web_persist.set_draft_election uuid se in
                            let msg = s_ "Your key has been received and checked!" in
                            let title = s_ "Success" in
                            return (title, msg, 200)
                          )
                )
            in
            Pages_common.generic_page ~title msg () >>= Html.send ~code
        )
    )

let () =
  Any.register ~service:election_draft_confirm
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          Pages_admin.election_draft_confirm uuid se () >>= Html.send
        )
    )

let () =
  Any.register ~service:election_draft_create
    (fun uuid () ->
      with_draft_election ~save:false uuid (fun se ->
          match%lwt validate_election uuid se with
          | () -> redir_preapply election_admin uuid ()
          | exception e ->
             Pages_admin.new_election_failure (`Exception e) () >>= Html.send
        )
    )

let destroy_election uuid =
  rmdir (!Web_config.spool_dir / raw_string_of_uuid uuid)

let () =
  Any.register ~service:election_draft_destroy
    (fun uuid () ->
      with_draft_election ~save:false uuid (fun _ ->
          let%lwt () = destroy_election uuid in
          Redirection.send (Redirection admin)
        )
    )

let () =
  Html.register ~service:election_draft_import
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          let%lwt _, a, b, c = get_elections_by_owner_sorted se.se_owner in
          Pages_admin.election_draft_import uuid se (a, b, c) ()
        )
    )

let () =
  Any.register ~service:election_draft_import_post
    (fun uuid from ->
      let from = uuid_of_raw_string from in
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let from_s = raw_string_of_uuid from in
          let%lwt voters = Web_persist.get_voters from in
          let%lwt passwords = Web_persist.get_passwords from in
          let get_password =
            match passwords with
            | None -> fun _ -> None
            | Some p -> fun sv_id ->
                        let _, login = split_identity sv_id in
                        SMap.find_opt login p
          in
          match voters with
          | Some voters ->
             if se.se_public_creds_received then
               forbidden ()
             else (
               se.se_voters <- merge_voters se.se_voters voters get_password;
               redir_preapply election_draft_voters uuid ()
             )
          | None ->
             Pages_common.generic_page ~title:(s_ "Error")
               ~service:(preapply ~service:election_draft_voters uuid)
               (Printf.sprintf
                  (f_ "Could not retrieve voter list from election %s")
                  from_s)
               () >>= Html.send
        )
    )

let () =
  Html.register ~service:election_draft_import_trustees
    (fun uuid () ->
      with_draft_election_ro uuid (fun se ->
          let%lwt _, a, b, c = get_elections_by_owner_sorted se.se_owner in
          Pages_admin.election_draft_import_trustees uuid se (a, b, c) ()
        )
    )

exception TrusteeImportError of string

let () =
  Any.register ~service:election_draft_import_trustees_post
    (fun uuid from ->
      let from = uuid_of_raw_string from in
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let%lwt metadata = Web_persist.get_election_metadata from in
          try%lwt
                match metadata.e_trustees with
                | None -> Lwt.fail (TrusteeImportError (s_ "Could not retrieve trustees from selected election!"))
                | Some names ->
                   let%lwt trustees = Web_persist.get_trustees from in
                   let module G = (val Group.of_string se.se_group : GROUP) in
                   let module K = Trustees.MakeCombinator (G) in
                   let trustees = trustees_of_string G.read trustees in
                   if not (K.check trustees) then
                     Lwt.fail (TrusteeImportError (s_ "Imported trustees are invalid for this election!"))
                   else
                     let import_pedersen t names =
                       let%lwt privs = Web_persist.get_private_keys from in
                       let%lwt se_threshold_trustees =
                         match privs with
                         | Some privs ->
                            let rec loop ts pubs privs accu =
                              match ts, pubs, privs with
                              | stt_id :: ts, vo_public_key :: pubs, vo_private_key :: privs ->
                                 let stt_name = vo_public_key.trustee_name in
                                 let%lwt stt_token = generate_token () in
                                 let stt_voutput = {vo_public_key; vo_private_key} in
                                 let stt_voutput = Some (string_of_voutput G.write stt_voutput) in
                                 let stt = {
                                     stt_id; stt_token; stt_voutput;
                                     stt_step = Some 7; stt_cert = None;
                                     stt_polynomial = None; stt_vinput = None;
                                     stt_name;
                                   } in
                                 loop ts pubs privs (stt :: accu)
                              | [], [], [] -> return (List.rev accu)
                              | _, _, _ -> Lwt.fail (TrusteeImportError (s_ "Inconsistency in imported election!"))
                            in loop names (Array.to_list t.t_verification_keys) privs []
                         | None -> Lwt.fail (TrusteeImportError (s_ "Encrypted decryption keys are missing!"))
                       in
                       se.se_threshold <- Some t.t_threshold;
                       se.se_threshold_trustees <- Some se_threshold_trustees;
                       se.se_threshold_parameters <- Some (string_of_threshold_parameters G.write t);
                       redir_preapply election_draft_threshold_trustees uuid ()
                     in
                     match trustees with
                     | [`Pedersen t] ->
                        import_pedersen t names
                     | [`Single x; `Pedersen t] when x.trustee_name = Some "server" ->
                        import_pedersen t (List.tl names)
                     | ts ->
                        let%lwt ts =
                          try
                            List.map
                              (function
                               | `Single x -> x
                               | `Pedersen _ -> raise (TrusteeImportError (s_ "Unsupported trustees!"))
                              ) ts
                            |> return
                          with
                          | e -> Lwt.fail e
                        in
                        let%lwt ts =
                          let module KG = Trustees.MakeSimple (G) (LwtRandom) in
                          List.combine names ts
                          |> Lwt_list.map_p
                               (fun (st_id, public_key) ->
                                 let%lwt st_token, st_private_key, st_public_key =
                                   if st_id = "server" then (
                                     let%lwt private_key = KG.generate () in
                                     let%lwt public_key = KG.prove private_key in
                                     let public_key = string_of_trustee_public_key G.write public_key in
                                     return ("", Some private_key, public_key)
                                   ) else (
                                     let%lwt st_token = generate_token () in
                                     let public_key = string_of_trustee_public_key G.write public_key in
                                     return (st_token, None, public_key)
                                   )
                                 in
                                 let st_name = public_key.trustee_name in
                                 return {st_id; st_token; st_public_key; st_private_key; st_name})
                        in
                        se.se_public_keys <- ts;
                        redir_preapply election_draft_trustees uuid ()
          with
          | TrusteeImportError msg ->
             Pages_common.generic_page ~title:(s_ "Error")
               ~service:(preapply ~service:election_draft_trustees uuid)
               msg () >>= Html.send
        )
    )

let election_admin_handler ?shuffle_token ?tally_token uuid =
     let%lwt l = get_preferred_gettext () in
     let open (val l) in
     let%lwt w = find_election uuid in
     let%lwt metadata = Web_persist.get_election_metadata uuid in
     let%lwt site_user = Eliom_reference.get Web_state.site_user in
     match w, site_user with
     | None, _ -> election_not_found ()
     | Some w, Some u when metadata.e_owner = Some u ->
        let%lwt state = Web_persist.get_election_state uuid in
        let module W = (val Election.get_group w) in
        let module E = Election.Make (W) (LwtRandom) in
        let%lwt pending_server_shuffle =
          match state with
          | `Shuffling ->
             if Election.has_nh_questions E.election then
               match%lwt Web_persist.get_shuffles uuid with
               | None -> return_true
               | Some _ -> return_false
             else return_false
          | _ -> return_false
        in
        let%lwt () =
          if pending_server_shuffle then (
            let%lwt cc = Web_persist.get_nh_ciphertexts uuid in
            let cc = nh_ciphertexts_of_string E.G.read cc in
            let%lwt shuffle = E.shuffle_ciphertexts cc in
            let shuffle = string_of_shuffle E.G.write shuffle in
            match%lwt Web_persist.append_to_shuffles uuid shuffle with
            | Some h ->
               let sh = {sh_trustee = "server"; sh_hash = h; sh_name = Some "server"} in
               let%lwt () = Web_persist.add_shuffle_hash uuid sh in
               Web_persist.remove_audit_cache uuid
            | None ->
               Lwt.fail (Failure (Printf.sprintf (f_ "Automatic shuffle by server has failed for election %s!") (raw_string_of_uuid uuid)))
          ) else return_unit
        in
        let get_tokens_decrypt () =
          (* this function is called only when there is a Pedersen trustee *)
          match%lwt Web_persist.get_decryption_tokens uuid with
          | Some x -> return x
          | None ->
            match metadata.e_trustees with
            | None -> failwith "missing trustees in get_tokens_decrypt"
            | Some ts ->
               let%lwt ts = Lwt_list.map_s (fun _ -> generate_token ()) ts in
               let%lwt () = Web_persist.set_decryption_tokens uuid ts in
               return ts
        in
        Pages_admin.election_admin ?shuffle_token ?tally_token w metadata state get_tokens_decrypt () >>= Html.send
     | _, Some _ ->
        let msg = s_ "You are not allowed to administer this election!" in
        Pages_common.generic_page ~title:(s_ "Forbidden") msg ()
        >>= Html.send ~code:403
     | _, _ ->
        redir_preapply site_login (None, ContSiteElection uuid) ()

let () =
  Any.register ~service:election_admin
    (fun uuid () -> election_admin_handler uuid)

let election_set_state state uuid () =
  with_site_user (fun u ->
      let%lwt metadata = Web_persist.get_election_metadata uuid in
      if metadata.e_owner = Some u then (
        let%lwt () =
          match%lwt Web_persist.get_election_state uuid with
          | `Open | `Closed -> return ()
          | _ -> forbidden ()
        in
        let state = if state then `Open else `Closed in
        let%lwt () = Web_persist.set_election_state uuid state in
        let%lwt dates = Web_persist.get_election_dates uuid in
        let%lwt () =
          Web_persist.set_election_dates uuid
            {dates with e_auto_open = None; e_auto_close = None}
        in
        redir_preapply election_admin uuid ()
      ) else forbidden ()
    )

let () = Any.register ~service:election_open (election_set_state true)
let () = Any.register ~service:election_close (election_set_state false)

let election_set_result_hidden f uuid x =
  with_site_user (fun u ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      let%lwt metadata = Web_persist.get_election_metadata uuid in
      if metadata.e_owner = Some u then (
        match%lwt Web_persist.set_election_result_hidden uuid (f l x) with
        | () -> redir_preapply election_admin uuid ()
        | exception Failure msg ->
           let service = preapply ~service:election_admin uuid in
           Pages_common.generic_page ~title:(s_ "Error") ~service msg () >>= Html.send
      ) else forbidden ()
    )

let parse_datetime_from_post l x =
  let open (val l : Web_i18n_sig.GETTEXT) in
  try datetime_of_string ("\"" ^ x ^ ".000000\"") with
  | _ -> Printf.ksprintf failwith (f_ "%s is not a valid date!") x

let () =
  Any.register ~service:election_hide_result
    (election_set_result_hidden
       (fun l x ->
         let open (val l : Web_i18n_sig.GETTEXT) in
         let t = parse_datetime_from_post l x in
         let max = datetime_add (now ()) (day days_to_publish_result) in
         if datetime_compare t max > 0 then
           Printf.ksprintf failwith
             (f_ "The date must be less than %d days in the future!")
             days_to_publish_result
         else
           Some t
       )
    )

let () =
  Any.register ~service:election_show_result
    (election_set_result_hidden (fun _ () -> None))

let () =
  Any.register ~service:election_auto_post
    (fun uuid (auto_open, auto_close) ->
      with_site_user (fun u ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          if metadata.e_owner = Some u then (
            let auto_dates =
              try
                let format x =
                  if x = "" then None
                  else Some (parse_datetime_from_post l x)
                in
                Ok (format auto_open, format auto_close)
              with Failure e -> Error e
            in
            match auto_dates with
            | Ok (e_auto_open, e_auto_close) ->
               let%lwt dates = Web_persist.get_election_dates uuid in
               let%lwt () =
                 Web_persist.set_election_dates uuid
                   {dates with e_auto_open; e_auto_close}
               in
               redir_preapply election_admin uuid ()
            | Error msg ->
               let service = preapply ~service:election_admin uuid in
               Pages_common.generic_page ~title:(s_ "Error") ~service msg () >>= Html.send
          ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_archive
    (fun uuid () ->
      with_site_user (fun u ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          if metadata.e_owner = Some u then (
            let%lwt () = archive_election uuid in
            redir_preapply election_admin uuid ()
          ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_delete
  (fun uuid () ->
    with_site_user (fun u ->
        let%lwt metadata = Web_persist.get_election_metadata uuid in
        if metadata.e_owner = Some u then (
          let%lwt () = delete_election uuid in
          redir_preapply admin () ()
        ) else forbidden ()
      )
  )

let () =
  let rex = Pcre.regexp "\".*\" \".*:(.*)\"" in
  Any.register ~service:election_missing_voters
    (fun (uuid, ()) () ->
      with_site_user (fun u ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          if metadata.e_owner = Some u then (
            let%lwt voters =
              match%lwt read_file ~uuid (string_of_election_file ESVoters) with
              | Some vs ->
                 return (
                     List.fold_left (fun accu v ->
                         let _, login = split_identity v in
                         SSet.add login accu
                       ) SSet.empty vs
                   )
              | None -> return SSet.empty
            in
            let%lwt voters =
              match%lwt read_file ~uuid (string_of_election_file ESRecords) with
              | Some rs ->
                 return (
                     List.fold_left (fun accu r ->
                         let s = Pcre.exec ~rex r in
                         let v = Pcre.get_substring s 1 in
                         SSet.remove v accu
                       ) voters rs
                   )
              | None -> return voters
            in
            let buf = Buffer.create 128 in
            SSet.iter (fun v ->
                Buffer.add_string buf v;
                Buffer.add_char buf '\n'
              ) voters;
            String.send (Buffer.contents buf, "text/plain")
          ) else forbidden ()
        )
    )

let () =
  let rex = Pcre.regexp "\"(.*)\\..*\" \".*:(.*)\"" in
  Any.register ~service:election_pretty_records
    (fun (uuid, ()) () ->
      with_site_user (fun u ->
          match%lwt find_election uuid with
          | None -> election_not_found ()
          | Some w ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          if metadata.e_owner = Some u then (
            let%lwt records =
              match%lwt read_file ~uuid (string_of_election_file ESRecords) with
              | Some rs ->
                 return (
                     List.rev_map (fun r ->
                         let s = Pcre.exec ~rex r in
                         let date = Pcre.get_substring s 1 in
                         let voter = Pcre.get_substring s 2 in
                         (date, voter)
                       ) rs
                   )
              | None -> return []
            in
            Pages_admin.pretty_records w (List.rev records) () >>= Html.send
          ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_project_result
    (fun ((uuid, ()), index) () ->
      let%lwt hidden =
        match%lwt Web_persist.get_election_result_hidden uuid with
        | None -> return_false
        | Some _ -> return_true
      in
      let%lwt () =
        if hidden then (
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          let%lwt site_user = Eliom_reference.get Web_state.site_user in
          match site_user with
          | Some u when metadata.e_owner = Some u -> return_unit
          | _ -> forbidden ()
        ) else return_unit
      in
      match%lwt Web_persist.get_election_result uuid with
      | None -> fail_http 404
      | Some result ->
         let full = Shape.to_shape_array result.result in
         if index < 0 || index >= Array.length full then
           fail_http 404
         else
           String.send (string_of_raw_result full.(index), "application/json")
    )

let copy_file src dst =
  let open Lwt_io in
  chars_of_file src |> chars_to_file dst

let try_copy_file src dst =
  if%lwt file_exists src then copy_file src dst else return_unit

let make_archive uuid =
  let uuid_s = raw_string_of_uuid uuid in
  let%lwt temp_dir =
    Lwt_preemptive.detach (fun () ->
        let temp_dir = Filename.temp_file "belenios" "archive" in
        Sys.remove temp_dir;
        Unix.mkdir temp_dir 0o700;
        Unix.mkdir (temp_dir / "public") 0o755;
        Unix.mkdir (temp_dir / "restricted") 0o700;
        temp_dir
      ) ()
  in
  let%lwt () =
    Lwt_list.iter_p (fun x ->
        try_copy_file (!Web_config.spool_dir / uuid_s / x) (temp_dir / "public" / x)
      ) [
        "election.json";
        "trustees.json";
        "public_creds.txt";
        "ballots.jsons";
        "result.json";
      ]
  in
  let%lwt () =
    Lwt_list.iter_p (fun x ->
        try_copy_file (!Web_config.spool_dir / uuid_s / x) (temp_dir / "restricted" / x)
      ) [
        "voters.txt";
        "records";
      ]
  in
  let command =
    Printf.ksprintf Lwt_process.shell
      "cd \"%s\" && zip -r archive public restricted" temp_dir
  in
  let%lwt r = Lwt_process.exec command in
  match r with
  | Unix.WEXITED 0 ->
     let fname = !Web_config.spool_dir / uuid_s / "archive.zip" in
     let fname_new = fname ^ ".new" in
     let%lwt () = copy_file (temp_dir / "archive.zip") fname_new in
     let%lwt () = Lwt_unix.rename fname_new fname in
     rmdir temp_dir
  | _ ->
     Printf.ksprintf Ocsigen_messages.errlog
       "Error while creating archive.zip for election %s, temporary directory left in %s"
       uuid_s temp_dir;
     return_unit

let () =
  Any.register ~service:election_download_archive
    (fun (uuid, ()) () ->
      with_site_user (fun u ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          let%lwt state = Web_persist.get_election_state uuid in
          if metadata.e_owner = Some u then (
            if state = `Archived then (
              let uuid_s = raw_string_of_uuid uuid in
              let archive_name = !Web_config.spool_dir / uuid_s / "archive.zip" in
              let%lwt b = file_exists archive_name in
              let%lwt () = if not b then make_archive uuid else return_unit in
              File.send ~content_type:"application/zip" archive_name
            ) else (
              let service = preapply ~service:election_admin uuid in
              Pages_common.generic_page ~title:(s_ "Error") ~service
                (s_ "The election is not archived!") () >>= Html.send
            )
          ) else forbidden ()
        )
    )

let find_trustee_id uuid token =
  match%lwt Web_persist.get_decryption_tokens uuid with
  | None -> return (int_of_string_opt token)
  | Some tokens ->
    let rec find i = function
      | [] -> None
      | t :: ts -> if t = token then Some i else find (i+1) ts
    in
    return (find 1 tokens)

let () =
  Any.register ~service:election_tally_trustees
    (fun (uuid, token) () ->
      without_site_user
        ~fallback:(fun _ ->
          election_admin_handler ~tally_token:token uuid
        )
        (fun () ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          match%lwt find_election uuid with
          | None -> election_not_found ()
          | Some w ->
             match%lwt Web_persist.get_election_state uuid with
             | `EncryptedTally _ ->
                (match%lwt find_trustee_id uuid token with
                 | Some trustee_id ->
                    let%lwt pds = Web_persist.get_partial_decryptions uuid in
                    if List.mem_assoc trustee_id pds then (
                      Pages_common.generic_page ~title:(s_ "Error")
                        (s_ "Your partial decryption has already been received and checked!")
                        () >>= Html.send
                    ) else (
                      Pages_admin.tally_trustees w trustee_id token () >>= Html.send
                    )
                 | None -> forbidden ()
                )
             | `Open | `Closed | `Shuffling ->
                let msg = s_ "The election is not ready to be tallied. Please come back later." in
                Pages_common.generic_page ~title:(s_ "Forbidden") msg () >>= Html.send ~code:403
             | `Tallied | `Archived ->
                let msg = s_ "The election has already been tallied." in
                Pages_common.generic_page ~title:(s_ "Forbidden") msg () >>= Html.send ~code:403
        )
    )

let () =
  Any.register ~service:election_tally_trustees_post
    (fun (uuid, token) partial_decryption ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      let%lwt () =
        match%lwt Web_persist.get_election_state uuid with
        | `EncryptedTally _ -> return ()
        | _ -> forbidden ()
      in
      let%lwt trustee_id =
        match%lwt find_trustee_id uuid token with
        | Some x -> return x
        | None -> forbidden ()
      in
      let%lwt pds = Web_persist.get_partial_decryptions uuid in
      let%lwt () =
        if List.mem_assoc trustee_id pds then forbidden () else return ()
      in
      let%lwt () =
        if trustee_id > 0 then return () else fail_http 404
      in
      match%lwt find_election uuid with
      | None -> election_not_found ()
      | Some election ->
      let module W = (val Election.get_group election) in
      let module E = Election.Make (W) (LwtRandom) in
      let%lwt pks =
        let%lwt trustees = Web_persist.get_trustees uuid in
        let trustees = trustees_of_string W.G.read trustees in
        trustees
        |> List.map
             (function
              | `Single x -> [x]
              | `Pedersen t -> Array.to_list t.t_verification_keys
             )
        |> List.flatten
        |> Array.of_list
        |> return
      in
      let pk = pks.(trustee_id-1).trustee_public_key in
      let pd = partial_decryption_of_string W.G.read partial_decryption in
      let et = !Web_config.spool_dir / raw_string_of_uuid uuid / string_of_election_file ESETally in
      let%lwt et = Lwt_io.chars_of_file et |> Lwt_stream.to_string in
      let et = encrypted_tally_of_string W.G.read et in
      if E.check_factor et pk pd then (
        let pds = (trustee_id, partial_decryption) :: pds in
        let%lwt () = Web_persist.set_partial_decryptions uuid pds in
        Pages_common.generic_page ~title:(s_ "Success")
          (s_ "Your partial decryption has been received and checked!") () >>=
        Html.send
      ) else (
        let service = preapply ~service:election_tally_trustees (uuid, token) in
        Pages_common.generic_page ~title:(s_ "Error") ~service
          (s_ "The partial decryption didn't pass validation!") () >>=
        Html.send
      ))

let handle_election_tally_release uuid () =
  with_site_user (fun u ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      let uuid_s = raw_string_of_uuid uuid in
      match%lwt find_election uuid with
      | None -> election_not_found ()
      | Some election ->
      let%lwt metadata = Web_persist.get_election_metadata uuid in
      let module W = (val Election.get_group election) in
      let module E = Election.Make (W) (LwtRandom) in
      if metadata.e_owner = Some u then (
        let%lwt () =
          match%lwt Web_persist.get_election_state uuid with
          | `EncryptedTally _ -> return_unit
          | _ -> forbidden ()
        in
        let%lwt ntallied = Web_persist.get_ballot_hashes uuid >|= List.length in
        let%lwt et =
          !Web_config.spool_dir / uuid_s / string_of_election_file ESETally |>
            Lwt_io.chars_of_file |> Lwt_stream.to_string >>=
            wrap1 (encrypted_tally_of_string W.G.read)
        in
        let%lwt trustees = Web_persist.get_trustees uuid in
        let trustees = trustees_of_string W.G.read trustees in
        let%lwt pds = Web_persist.get_partial_decryptions uuid in
        let pds = List.map snd pds in
        let pds = List.map (partial_decryption_of_string W.G.read) pds in
        let%lwt shuffles, shufflers =
          match%lwt Web_persist.get_shuffles uuid with
          | None -> return (None, None)
          | Some s ->
             let s = List.map (shuffle_of_string W.G.read) s in
             match%lwt Web_persist.get_shuffle_hashes uuid with
             | None -> return (Some s, None)
             | Some x ->
                let x =
                  x
                  |> List.map (fun x -> if x.sh_hash = "" then [] else [x.sh_name])
                  |> List.flatten
                in
                assert (List.length s = List.length x);
                return (Some s, Some x)
        in
        match E.compute_result ?shuffles ?shufflers ntallied et pds trustees with
        | Ok result ->
           let%lwt () =
             let result = string_of_election_result W.G.write result in
             write_file ~uuid (string_of_election_file ESResult) [result]
           in
           let%lwt () = Web_persist.remove_audit_cache uuid in
           let%lwt () = Web_persist.set_election_state uuid `Tallied in
           let%lwt dates = Web_persist.get_election_dates uuid in
           let%lwt () = Web_persist.set_election_dates uuid {dates with e_tally = Some (now ())} in
           let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "decryption_tokens.json") in
           let%lwt () = cleanup_file (!Web_config.spool_dir / uuid_s / "shuffles.jsons") in
           let%lwt () = Web_persist.clear_shuffle_token uuid in
           redir_preapply election_home (uuid, ()) ()
        | Error e ->
           let msg =
             Printf.sprintf
               (f_ "An error occurred while computing the result (%s). Most likely, it means that some trustee has not done his/her job.")
               (Trustees.string_of_combination_error e)
           in
           Pages_common.generic_page ~title:(s_ "Error") msg () >>= Html.send
      ) else forbidden ()
    )

let () =
  Any.register ~service:election_tally_release
    handle_election_tally_release

module type ELECTION_LWT = ELECTION with type 'a m = 'a Lwt.t

let perform_server_side_decryption uuid e metadata tally =
  let module E = (val e : ELECTION_LWT) in
  let tally = encrypted_tally_of_string E.G.read tally in
  let decrypt i =
    match%lwt Web_persist.get_private_key uuid with
    | Some sk ->
       let%lwt pd = E.compute_factor tally sk in
       let pd = string_of_partial_decryption E.G.write pd in
       Web_persist.set_partial_decryptions uuid [i, pd]
    | None ->
       Printf.ksprintf failwith
         "missing private key for server in election %s"
         (raw_string_of_uuid uuid)
  in
  let trustees =
    match metadata.e_trustees with
    | None -> ["server"]
    | Some ts -> ts
  in
  trustees
  |> List.mapi (fun i t -> i, t)
  |> Lwt_list.exists_s
       (fun (i, t) ->
         if t = "server" then (
           let%lwt () = decrypt (i + 1) in
           return_false
         ) else return_true
       )

let transition_to_encrypted_tally uuid e metadata tally =
  let%lwt () =
    Web_persist.set_election_state uuid (`EncryptedTally (0, 0, ""))
  in
  if%lwt perform_server_side_decryption uuid e metadata tally then
    redir_preapply election_admin uuid ()
  else
    handle_election_tally_release uuid ()

let () =
  Any.register ~service:election_compute_encrypted_tally
    (fun uuid () ->
      with_site_user (fun u ->
          match%lwt find_election uuid with
          | None -> election_not_found ()
          | Some election ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          let module W = (val Election.get_group election) in
          let module E = Election.Make (W) (LwtRandom) in
          if metadata.e_owner = Some u then (
            let%lwt () =
              match%lwt Web_persist.get_election_state uuid with
              | `Closed -> return ()
              | _ -> forbidden ()
            in
            let%lwt tally =
              match%lwt Web_persist.compute_encrypted_tally uuid with
              | Some x -> return x
              | None -> failwith "Anomaly in election_compute_encrypted_tally service handler. Please report." (* should not happen *)
            in
            if Election.has_nh_questions E.election then (
              let%lwt () = Web_persist.set_election_state uuid `Shuffling in
              redir_preapply election_admin uuid ()
            ) else (
              transition_to_encrypted_tally uuid (module E) metadata tally
            )
          ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_shuffle_link
    (fun (uuid, token) () ->
      without_site_user
        ~fallback:(fun _ ->
          election_admin_handler ~shuffle_token:token uuid
        )
        (fun () ->
          let%lwt expected_token = Web_persist.get_shuffle_token uuid in
          match expected_token with
          | Some x when token = x.tk_token ->
             (match%lwt find_election uuid with
              | None -> election_not_found ()
              | Some election -> Pages_admin.shuffle election token >>= Html.send
             )
          | _ -> forbidden ()
        )
    )

let () =
  Any.register ~service:election_shuffle_post
    (fun (uuid, token) shuffle ->
      without_site_user (fun () ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          let%lwt expected_token = Web_persist.get_shuffle_token uuid in
          match expected_token with
          | Some x when token = x.tk_token ->
             (match%lwt Web_persist.append_to_shuffles uuid shuffle with
              | Some h ->
                 let%lwt () = Web_persist.clear_shuffle_token uuid in
                 let sh = {sh_trustee = x.tk_trustee; sh_hash = h; sh_name = x.tk_name} in
                 let%lwt () = Web_persist.add_shuffle_hash uuid sh in
                 let%lwt () = Web_persist.remove_audit_cache uuid in
                 Pages_common.generic_page ~title:(s_ "Success") (s_ "The shuffle has been successfully applied!") () >>= Html.send
              | None ->
                 Pages_common.generic_page ~title:(s_ "Error") (s_ "An error occurred while applying the shuffle.") () >>= Html.send
              | exception e ->
                 Pages_common.generic_page ~title:(s_ "Error") (Printf.sprintf (f_ "Data is invalid! (%s)") (Printexc.to_string e)) () >>= Html.send
             )
          | _ -> forbidden ()
        )
    )

let extract_names trustees =
  trustees
  |> List.map
       (function
        | `Pedersen x ->
           x.t_verification_keys
           |> Array.to_list
           |> List.map (fun x -> x.trustee_name)
        | `Single x -> [x.trustee_name]
       )
  |> List.flatten

let get_trustee_names uuid =
  let%lwt trustees = Web_persist.get_trustees uuid in
  let trustees = trustees_of_string Yojson.Safe.read_json trustees in
  return (extract_names trustees)

let get_trustee_name uuid metadata trustee =
  match metadata.e_trustees with
  | None -> return_none
  | Some xs ->
     let%lwt names = get_trustee_names uuid in
     return (List.assoc trustee (List.combine xs names))

let () =
  Any.register ~service:election_shuffler_select
    (fun () (uuid, trustee) ->
      let uuid = uuid_of_raw_string uuid in
      with_site_user (fun u ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          let%lwt name = get_trustee_name uuid metadata trustee in
          if metadata.e_owner = Some u then (
            let%lwt () = Web_persist.clear_shuffle_token uuid in
            let%lwt _ = Web_persist.gen_shuffle_token uuid trustee name in
            redir_preapply election_admin uuid ()
          ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_shuffler_skip_confirm
    (fun () (uuid, trustee) ->
      let uuid = uuid_of_raw_string uuid in
      with_site_user (fun u ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          if metadata.e_owner = Some u then (
            Pages_admin.election_shuffler_skip_confirm uuid trustee >>= Html.send
          ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_shuffler_skip
    (fun () (uuid, trustee) ->
      let uuid = uuid_of_raw_string uuid in
      with_site_user (fun u ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          let%lwt sh_name = get_trustee_name uuid metadata trustee in
          if metadata.e_owner = Some u then (
            let%lwt () = Web_persist.clear_shuffle_token uuid in
            let sh = {sh_trustee = trustee; sh_hash = ""; sh_name} in
            let%lwt () = Web_persist.add_shuffle_hash uuid sh in
            redir_preapply election_admin uuid ()
          ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_decrypt (fun uuid () ->
      with_site_user (fun u ->
          match%lwt find_election uuid with
          | None -> election_not_found ()
          | Some election ->
          let%lwt metadata = Web_persist.get_election_metadata uuid in
          let module W = (val Election.get_group election) in
          let module E = Election.Make (W) (LwtRandom) in
          if metadata.e_owner = Some u then (
            let%lwt () =
              match%lwt Web_persist.get_election_state uuid with
              | `Shuffling -> return ()
              | _ -> forbidden ()
            in
            let%lwt tally =
              match%lwt Web_persist.compute_encrypted_tally_after_shuffling uuid with
              | Some x -> return x
              | None -> Lwt.fail (Failure "election_decrypt handler: compute_encrypted_tally_after_shuffling")
            in
            transition_to_encrypted_tally uuid (module E) metadata tally
          ) else forbidden ()
        )
    )

let () =
  Any.register ~service:election_draft_threshold_set
    (fun uuid threshold ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          match se.se_threshold_trustees with
          | None ->
             let msg = s_ "Please add some trustees first!" in
             let service = preapply ~service:election_draft_threshold_trustees uuid in
             Pages_common.generic_page ~title:(s_ "Error") ~service msg () >>= Html.send
          | Some xs ->
             let maybe_threshold, step =
               if threshold = 0 then None, None
               else Some threshold, Some 1
             in
             if threshold >= 0 && threshold < List.length xs then (
               List.iter (fun x -> x.stt_step <- step) xs;
               se.se_threshold <- maybe_threshold;
               redir_preapply election_draft_threshold_trustees uuid ()
             ) else (
               let msg = s_ "The threshold must be positive and smaller than the number of trustees!" in
               let service = preapply ~service:election_draft_threshold_trustees uuid in
               Pages_common.generic_page ~title:(s_ "Error") ~service msg () >>= Html.send
             )
        )
    )

let () =
  Any.register ~service:election_draft_threshold_trustee_add
    (fun uuid (stt_id, name) ->
      with_draft_election uuid (fun se ->
          let%lwt l = get_preferred_gettext () in
          let open (val l) in
          if is_email stt_id then (
            let stt_name = Some name in
            let%lwt stt_token = generate_token () in
            let trustee = {
                stt_id; stt_token; stt_step = None;
                stt_cert = None; stt_polynomial = None;
                stt_vinput = None; stt_voutput = None;
                stt_name;
              } in
            let trustees =
              match se.se_threshold_trustees with
              | None -> Some [trustee]
              | Some t -> Some (t @ [trustee])
            in
            se.se_threshold_trustees <- trustees;
            redir_preapply election_draft_threshold_trustees uuid ()
          ) else (
            let msg = Printf.sprintf (f_ "%s is not a valid e-mail address!") stt_id in
            let service = preapply ~service:election_draft_threshold_trustees uuid in
            Pages_common.generic_page ~title:(s_ "Error") ~service msg () >>= Html.send
          )
        )
    )

let () =
  Any.register ~service:election_draft_threshold_trustee_del
    (fun uuid index ->
      with_draft_election uuid (fun se ->
          let trustees =
            let trustees =
              match se.se_threshold_trustees with
              | None -> []
              | Some x -> x
            in
            trustees |>
              List.mapi (fun i x -> i, x) |>
              List.filter (fun (i, _) -> i <> index) |>
              List.map snd
          in
          let trustees = match trustees with [] -> None | x -> Some x in
          se.se_threshold_trustees <- trustees;
          redir_preapply election_draft_threshold_trustees uuid ()
        )
    )

let () =
  Any.register ~service:election_draft_threshold_trustee
    (fun (uuid, token) () ->
      without_site_user
        ~fallback:(fun u ->
          match%lwt Web_persist.get_draft_election uuid with
          | None -> fail_http 404
          | Some se ->
             if se.se_owner = u then (
               Pages_admin.election_draft_threshold_trustees ~token uuid se () >>= Html.send
             ) else forbidden ()
        )
        (fun () ->
          match%lwt Web_persist.get_draft_election uuid with
          | None -> fail_http 404
          | Some se -> Pages_admin.election_draft_threshold_trustee token uuid se () >>= Html.send
        )
    )

let wrap_handler_without_site_user f =
  without_site_user (fun () -> wrap_handler f)

let () =
  Any.register ~service:election_draft_threshold_trustee_post
    (fun (uuid, token) data ->
      wrap_handler_without_site_user
        (fun () ->
          let%lwt () =
            Web_election_mutex.with_lock uuid
              (fun () ->
                match%lwt Web_persist.get_draft_election uuid with
                | None -> fail_http 404
                | Some se ->
                   let ts =
                     match se.se_threshold_trustees with
                     | None -> failwith "No threshold trustees"
                     | Some xs -> Array.of_list xs
                   in
                   let i, t =
                     match Array.findi (fun i x ->
                               if token = x.stt_token then Some (i, x) else None
                             ) ts with
                     | Some (i, t) -> i, t
                     | None -> failwith "Trustee not found"
                   in
                   let get_certs () =
                     let certs = Array.map (fun x ->
                                     match x.stt_cert with
                                     | None -> failwith "Missing certificate"
                                     | Some y -> y
                                   ) ts in
                     {certs}
                   in
                   let get_polynomials () =
                     Array.map (fun x ->
                         match x.stt_polynomial with
                         | None -> failwith "Missing polynomial"
                         | Some y -> y
                       ) ts
                   in
                   let module G = (val Group.of_string se.se_group : GROUP) in
                   let module P = Trustees.MakePKI (G) (LwtRandom) in
                   let module C = Trustees.MakeChannels (G) (LwtRandom) (P) in
                   let module K = Trustees.MakePedersen (G) (LwtRandom) (P) (C) in
                   let%lwt () =
                     match t.stt_step with
                     | Some 1 ->
                        let cert = cert_of_string data in
                        if K.step1_check cert then (
                          t.stt_cert <- Some cert;
                          t.stt_step <- Some 2;
                          return_unit
                        ) else (
                          failwith "Invalid certificate"
                        )
                     | Some 3 ->
                        let certs = get_certs () in
                        let polynomial = polynomial_of_string data in
                        if K.step3_check certs i polynomial then (
                          t.stt_polynomial <- Some polynomial;
                          t.stt_step <- Some 4;
                          return_unit
                        ) else (
                          failwith "Invalid polynomial"
                        )
                     | Some 5 ->
                        let certs = get_certs () in
                        let polynomials = get_polynomials () in
                        let voutput = voutput_of_string G.read data in
                        if K.step5_check certs i polynomials voutput then (
                          t.stt_voutput <- Some data;
                          t.stt_step <- Some 6;
                          return_unit
                        ) else (
                          failwith "Invalid voutput"
                        )
                     | _ -> failwith "Unknown step"
                   in
                   let%lwt () =
                     if Array.forall (fun x -> x.stt_step = Some 2) ts then (
                       (try
                          K.step2 (get_certs ());
                          Array.iter (fun x -> x.stt_step <- Some 3) ts;
                        with e ->
                          se.se_threshold_error <- Some (Printexc.to_string e)
                       ); return_unit
                     ) else return_unit
                   in
                   let%lwt () =
                     if Array.forall (fun x -> x.stt_step = Some 4) ts then (
                       (try
                          let certs = get_certs () in
                          let polynomials = get_polynomials () in
                          let vinputs = K.step4 certs polynomials in
                          for j = 0 to Array.length ts - 1 do
                            ts.(j).stt_vinput <- Some vinputs.(j)
                          done;
                          Array.iter (fun x -> x.stt_step <- Some 5) ts
                        with e ->
                          se.se_threshold_error <- Some (Printexc.to_string e)
                       ); return_unit
                     ) else return_unit
                   in
                   let%lwt () =
                     if Array.forall (fun x -> x.stt_step = Some 6) ts then (
                       (try
                          let certs = get_certs () in
                          let polynomials = get_polynomials () in
                          let voutputs = Array.map (fun x ->
                                             match x.stt_voutput with
                                             | None -> failwith "Missing voutput"
                                             | Some y -> voutput_of_string G.read y
                                           ) ts in
                          let p = K.step6 certs polynomials voutputs in
                          se.se_threshold_parameters <- Some (string_of_threshold_parameters G.write p);
                          Array.iter (fun x -> x.stt_step <- Some 7) ts
                        with e ->
                          se.se_threshold_error <- Some (Printexc.to_string e)
                       ); return_unit
                     ) else return_unit
                   in
                   Web_persist.set_draft_election uuid se
              )
          in
          redir_preapply election_draft_threshold_trustee (uuid, token) ()
        )
    )

module HashedInt = struct
  type t = int
  let equal = (=)
  let hash x = x
end

module Captcha_throttle = Lwt_throttle.Make (HashedInt)
let captcha_throttle = Captcha_throttle.create ~rate:1 ~max:5 ~n:1

let signup_captcha_handler service error email =
  let%lwt l = get_preferred_gettext () in
  let open (val l) in
  if%lwt Captcha_throttle.wait captcha_throttle 0 then
    let%lwt challenge = Web_signup.create_captcha () in
    Pages_admin.signup_captcha ~service error challenge email
  else
    let service = preapply ~service:signup_captcha service in
    Pages_common.generic_page ~title:(s_ "Account creation") ~service
      (s_ "You cannot create an account now. Please try later.") ()

let () =
  Html.register ~service:signup_captcha
    (fun service () ->
      if%lwt Eliom_reference.get Web_state.show_cookie_disclaimer then
        Pages_admin.privacy_notice (ContSignup service)
      else
        signup_captcha_handler service None ""
    )

let () =
  Html.register ~service:signup_captcha_post
    (fun service (challenge, (response, email)) ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      let%lwt error =
        let%lwt ok = Web_signup.check_captcha ~challenge ~response in
        if ok then
          if is_email email then return_none else return_some BadAddress
        else return_some BadCaptcha
      in
      match error with
      | None ->
         let%lwt () = Web_signup.send_confirmation_link ~service email in
         let message =
           Printf.sprintf
             (f_ "An e-mail was sent to %s with a confirmation link. Please click on it to complete account creation.") email
         in
         Pages_common.generic_page ~title:(s_ "Account creation") message ()
      | _ -> signup_captcha_handler service error email
    )

let changepw_captcha_handler service error email username =
  let%lwt l = get_preferred_gettext () in
  let open (val l) in
  if%lwt Captcha_throttle.wait captcha_throttle 1 then
    let%lwt challenge = Web_signup.create_captcha () in
    Pages_admin.signup_changepw ~service error challenge email username
  else
    let service = preapply ~service:changepw_captcha service in
    Pages_common.generic_page ~title:(s_ "Change password") ~service
      (s_ "You cannot change your password now. Please try later.") ()

let () =
  Html.register ~service:changepw_captcha
    (fun service () -> changepw_captcha_handler service None "" "")

let () =
  Html.register ~service:changepw_captcha_post
    (fun service (challenge, (response, (email, username))) ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      let%lwt error =
        let%lwt ok = Web_signup.check_captcha ~challenge ~response in
        if ok then return_none
        else return_some BadCaptcha
      in
      match error with
      | None ->
         let%lwt () =
           match%lwt Web_auth_password.lookup_account ~service ~email ~username with
           | None ->
              return (
                  Printf.ksprintf Ocsigen_messages.warning
                    "Unsuccessful attempt to change the password of %S (%S) for service %s"
                    username email service
                )
           | Some (username, address) ->
              Web_signup.send_changepw_link ~service ~address ~username
         in
         let message =
           s_ "If the account exists, an e-mail was sent with a confirmation link. Please click on it to change your password."
         in
         Pages_common.generic_page ~title:(s_ "Change password") message ()
      | _ -> changepw_captcha_handler service error email username
    )

let () =
  String.register ~service:signup_captcha_img
    (fun challenge () -> Web_signup.get_captcha ~challenge)

let () =
  Any.register ~service:signup_login
    (fun token () ->
      match%lwt Web_signup.confirm_link token with
      | None -> forbidden ()
      | Some env ->
         let%lwt () = Eliom_reference.set Web_state.signup_env (Some env) in
         redir_preapply signup () ()
    )

let () =
  Html.register ~service:signup
    (fun () () ->
      match%lwt Eliom_reference.get Web_state.signup_env with
      | None -> forbidden ()
      | Some (_, _, address, Web_signup.CreateAccount) -> Pages_admin.signup address None ""
      | Some (_, _, address, Web_signup.ChangePassword username) -> Pages_admin.changepw ~username ~address None
    )

let () =
  Html.register ~service:signup_post
    (fun () (username, (password, password2)) ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      match%lwt Eliom_reference.get Web_state.signup_env with
      | Some (token, service, email, Web_signup.CreateAccount) ->
         if password = password2 then (
           let user = { user_name = username; user_domain = service } in
           match%lwt Web_auth_password.add_account user ~password ~email with
           | Ok () ->
              let%lwt () = Web_signup.remove_link token in
              let%lwt () = Eliom_reference.unset Web_state.signup_env in
              let service = preapply ~service:site_login (Some service, ContSiteAdmin) in
              Pages_common.generic_page ~title:(s_ "Account creation") ~service (s_ "The account has been created.") ()
           | Error e -> Pages_admin.signup email (Some e) username
         ) else Pages_admin.signup email (Some PasswordMismatch) username
      | _ -> forbidden ()
    )

let () =
  Html.register ~service:changepw_post
    (fun () (password, password2) ->
      let%lwt l = get_preferred_gettext () in
      let open (val l) in
      match%lwt Eliom_reference.get Web_state.signup_env with
      | Some (token, service, address, Web_signup.ChangePassword username) ->
         if password = password2 then (
           let user = { user_name = username; user_domain = service } in
           match%lwt Web_auth_password.change_password user ~password with
           | Ok () ->
              let%lwt () = Web_signup.remove_link token in
              let%lwt () = Eliom_reference.unset Web_state.signup_env in
              let service = preapply ~service:site_login (Some service, ContSiteAdmin) in
              Pages_common.generic_page ~title:(s_ "Change password") ~service (s_ "The password has been changed.") ()
           | Error e -> Pages_admin.changepw ~username ~address (Some e)
         ) else Pages_admin.changepw ~username ~address (Some PasswordMismatch)
      | _ -> forbidden ()
    )

let extract_automatic_data_draft uuid_s =
  let uuid = uuid_of_raw_string uuid_s in
  match%lwt Web_persist.get_draft_election uuid with
  | None -> return_none
  | Some se ->
     let name = se.se_questions.t_name in
     let contact = se.se_metadata.e_contact in
     let t = Option.get se.se_creation_date default_creation_date in
     let next_t = datetime_add t (day days_to_delete) in
     return_some (`Destroy, uuid, next_t, name, contact)

let extract_automatic_data_validated uuid_s =
  let uuid = uuid_of_raw_string uuid_s in
  let%lwt election = Web_persist.get_raw_election uuid in
  match election with
  | None -> return_none
  | Some election ->
     let election = Election.of_string election in
     let%lwt metadata = Web_persist.get_election_metadata uuid in
     let name = election.e_params.e_name in
     let contact = metadata.e_contact in
     let%lwt state = Web_persist.get_election_state uuid in
     let%lwt dates = Web_persist.get_election_dates uuid in
     match state with
     | `Open | `Closed | `Shuffling | `EncryptedTally _ ->
        let t = Option.get dates.e_finalization default_validation_date in
        let next_t = datetime_add t (day days_to_delete) in
        return_some (`Delete, uuid, next_t, name, contact)
     | `Tallied ->
        let t = Option.get dates.e_tally default_tally_date in
        let next_t = datetime_add t (day days_to_archive) in
        return_some (`Archive, uuid, next_t, name, contact)
     | `Archived ->
        let t = Option.get dates.e_archive default_archive_date in
        let next_t = datetime_add t (day days_to_delete) in
        return_some (`Delete, uuid, next_t, name, contact)

let try_extract extract x =
  try%lwt extract x with _ -> return_none

let get_next_actions () =
  Lwt_unix.files_of_directory !Web_config.spool_dir |>
  Lwt_stream.to_list >>=
  Lwt_list.filter_map_s
    (fun x ->
      if x = "." || x = ".." then return_none
      else (
        match%lwt try_extract extract_automatic_data_draft x with
        | None -> try_extract extract_automatic_data_validated x
        | x -> return x
      )
    )

let mail_automatic_warning : ('a, 'b, 'c, 'd, 'e, 'f) format6 =
  "The election %s will be automatically %s after %s.

-- \nBelenios"

let process_election_for_data_policy (action, uuid, next_t, name, contact) =
  let uuid_s = raw_string_of_uuid uuid in
  let now = now () in
  let action, comment = match action with
    | `Destroy -> destroy_election, "destroyed"
    | `Delete -> delete_election, "deleted"
    | `Archive -> archive_election, "archived"
  in
  if datetime_compare now next_t > 0 then (
    let%lwt () = action uuid in
    return (
        Printf.ksprintf Ocsigen_messages.warning
          "Election %s has been automatically %s" uuid_s comment
      )
  ) else (
    let mail_t = datetime_add next_t (day (-days_to_mail)) in
    if datetime_compare now mail_t > 0 then (
      let%lwt dates = Web_persist.get_election_dates uuid in
      let send = match dates.e_last_mail with
        | None -> true
        | Some t ->
           let next_mail_t = datetime_add t (day days_between_mails) in
           datetime_compare now next_mail_t > 0
      in
      if send then (
        match contact with
        | None -> return_unit
        | Some contact ->
           match extract_email contact with
           | None -> return_unit
           | Some email ->
              let subject =
                Printf.sprintf "Election %s will be automatically %s soon"
                  name comment
              in
              let body =
                Printf.sprintf mail_automatic_warning
                  name comment (format_datetime next_t)
              in
              let%lwt () = send_email email subject body in
              Web_persist.set_election_dates uuid {dates with e_last_mail = Some now}
      ) else return_unit
    ) else return_unit
  )

let rec data_policy_loop () =
  let open Ocsigen_messages in
  let () = accesslog "Data policy process started" in
  let%lwt elections = get_next_actions () in
  let%lwt () = Lwt_list.iter_s process_election_for_data_policy elections in
  let () = accesslog "Data policy process completed" in
  let%lwt () = Lwt_unix.sleep 3600. in
  data_policy_loop ()
