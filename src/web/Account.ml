
(** Account management and page ACL
    @author Sylvain Le Gall
  *)

open Lwt
open XHTML.M
open Eliom_services
open Eliom_parameters
open Eliom_sessions
open Eliom_predefmod.Xhtml
open ODBGettext
open SQL

type account =
    {
      accnt_id:   int32;
      accnt_name: string;
    }

type t = 
  | Anon
  | User of account 
  | Admin of account

let name_of_role =
  function
    | Anon -> "anonymous"
    | User t | Admin t -> t.accnt_name

let string_of_role =
  function
    | Anon  -> s_ "anonymous"
    | User accnt -> 
        Printf.sprintf 
          (f_ "user %s") 
          accnt.accnt_name

    | Admin accnt -> 
        Printf.sprintf 
          (f_ "administrator %s")
          accnt.accnt_name


let get ~sp () = 
  let the =
    function 
      | Some i -> i
      | None -> assert(false)
  in
   catch 
     (fun () ->
        let cookies =
          Eliom_sessions.get_cookies sp
        in
          begin
            try 
              return 
                 (Netencoding.Url.decode
                    (Ocsigen_lib.String_Table.find 
                       "account_ext_token"
                       cookies))
             with Not_found ->
               fail 
                 (Failure (s_ "Forge cookie not found"))
          end

        >>= fun token ->
          Lwt_pool.use SQL.pool
            (fun db -> 
               PGSQL(db) 
                 "SELECT user_id, realname FROM account_ext \
                     WHERE token = $token")

        >>= 
        (function
           | e :: _ -> 
               return e
           | [] -> 
               fail (Failure (s_ "Cannot found token in DB")))

        >>= 
        (fun (user_id, realname) ->
           return
             (User
                {
                  accnt_id   = the user_id;
                  accnt_name = the realname;
                }))
     )
     
     (function
        | Failure msg ->
            return Anon
        | e ->
            fail e)

let self_uri ~sp = 
  let proto =
    if get_ssl ~sp then
      "https"
    else
      "http"
  in
  let port =
    match get_server_port ~sp with 
      | 80 -> ""
      | n -> ":"^(string_of_int n)
  in
  let suff =
    match get_suffix ~sp with
      | Some lst -> "/"^(String.concat "/" lst)
      | None -> ""
  in
    Printf.sprintf 
      "%s://%s%s%s%s"
      proto
      (get_hostname ~sp)
      port
      (get_full_url ~sp)
      suff

(* TODO: refactor with above *)
let service_uri ~sp service =
  let proto =
    if get_ssl ~sp then
      "https"
    else
      "http"
  in
  let port =
    match get_server_port ~sp with 
      | 80 -> ""
      | n -> ":"^(string_of_int n)
  in
  let suff =
    make_string_uri 
      ~absolute_path:true 
      ~service
      ~sp 
      ()
  in
    (* TODO: use make_proto_prefix *)
    Printf.sprintf 
      "%s://%s%s%s"
      proto
      (get_hostname ~sp)
      port
      suff

let account_ext = 
  if ODBConf.dev then
    AccountStub.main
  else
    new_external_service
      ~prefix:"http://localhost"
      ~path:["~gildor"; "account-ext.php"]
      ~get_params:(string "action" ** 
                   opt (string "redirect"))
      ~post_params:unit
      ()

let mk_account sp action =
  preapply account_ext (action, Some (self_uri ~sp))

let logout_ext sp =
  mk_account sp "logout"

let my_account =
  new_service 
    ~path:["my_account"] 
    ~get_params:(opt (int64 "log_offset"))
    ()

let login_ext sp =
  preapply 
    account_ext 
    ("login", 
     Some (service_uri ~sp (preapply my_account None)))

let new_account_ext sp =
  mk_account sp "new"

let manage_account_ext sp =
  mk_account sp "manage"

let lost_passwd_ext sp =
  mk_account sp "lost_passwd"

let new_account = 
  new_service 
    ~path:["new_account"] 
    ~get_params:unit 
    ()

let box role sp = 
  match role with 
    | User _ | Admin _->
        [ul 
           (li [a (logout_ext sp) sp [pcdata (s_ "Log Out")] ()])
           [li [a my_account sp  [pcdata (s_ "My account")] None]]]
    | Anon ->
        [ul
           (li [a (login_ext sp) sp  [pcdata (s_ "Log In")] ()])
           [li [a new_account sp [pcdata (s_ "New account")] ()]]]
