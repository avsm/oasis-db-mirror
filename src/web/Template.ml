
open Lwt
open XHTML.M
open Eliom_services
open Eliom_parameters
open Eliom_sessions
open Eliom_predefmod.Xhtml
open ODBGettext
open Context
open Account
open Common

let mk_static_uri sp path =
  make_uri
    ~service:(static_dir sp) 
    ~sp
    path

type title =
  | OneTitle of string 
  | BrowserAndPageTitle of string * string 

let template_skeleton ~sp ~title ?(extra_headers=[]) ~div_id account_box ctnt = 
  let mk_static_uri path =
    mk_static_uri sp path
  in
  let mk_sponsor nm url logo = 
    let url =
      uri_of_string url
    in
    let logo =
      mk_static_uri logo
    in
      XHTML.M.a ~a:[a_href url]
        [pcdata nm],
      XHTML.M.a ~a:[a_href url]
        [img ~alt:nm ~src:logo ()]
  in

  let ocamlcore_link, ocamlcore_logo  = 
    mk_sponsor
      "OCamlCore"
      "http://www.ocamlcore.com"
      ["ocamlcore-logo_badge.png"]
  in

  let janest_link, janest_logo = 
    mk_sponsor
      "Jane Street Capital"
      "http://www.janestreet.com"
      ["jane-street-logo_badge.png"]
  in

  let browser_ttl, page_ttl =
    match title with
      | OneTitle ttl -> ttl, ttl
      | BrowserAndPageTitle (bttl, pttl) -> bttl, pttl
  in
    html 
      (head 
         (XHTML.M.title 
            (pcdata 
               (Printf.sprintf "OASIS DB: %s" browser_ttl)))
         (link ~a:[a_rel [`Stylesheet];
                   a_href (mk_static_uri ["default.css"]);
                   a_type "text/css"] ()
          ::
          link ~a:[a_rel [`Other "shortcut icon"];
                   a_href (mk_static_uri ["caml.ico"]);
                   a_type "images/ico"] ()
          ::
          extra_headers))
      (body 
         [div ~a:[a_id "top"]
            [div ~a:[a_id "header"]
               [div ~a:[a_id "title"]
                  [a home sp [pcdata "OASIS DB"] ()];
                div ~a:[a_id "subtitle"]
                  [pcdata (s_ "an OCaml packages archive")]];
             
             account_box;

             div ~a:[a_id "menu"]
             (*
               [Eliom_tools.menu
                  ~id:"menu"
                  (home (), [pcdata (s_ "Home")])
                  [
                    browse (),     [pcdata (s_ "Browse")];
                    upload (),     [pcdata (s_ "Upload")];
                    contribute (), [pcdata (s_ "Contribute")];
                  ]
                  ~sp ()];
              *)
               [ul
                  (li [a home sp       [pcdata (s_ "Home")] ()])
                  [li [a browse sp     [pcdata (s_ "Browse")] ()];
                   li [a upload sp     [pcdata (s_ "Upload")] ()];
                   li [a contribute sp [pcdata (s_ "Contribute")] ()]]];

             if ODBConf.dev then
               div ~a:[a_id "dev_warning"]
                 [
                   p [pcdata 
                        (Printf.sprintf
                           (f_ "This is the development version %s of \
                             OASIS-DB. Packages uploaded here will be \
                             removed. Use this website to test your \
                             packages or help the OASIS-DB project to \
                             find bugs.")
                           ODBConf.version)];
                   XHTML.M.a
                     ~a:[a_href (uri_of_string "https://forge.ocamlcore.org/tracker/?group_id=54")]
                     [pcdata (s_ "Submit bug reports or feature requests")];
                   pcdata " | ";
                   XHTML.M.a
                     ~a:[a_href (uri_of_string "http://oasis.ocamlcore.org/")]
                     [pcdata (s_ "Go to the real OASIS-DB website")];
                 ]
             else
               pcdata "";

             div ~a:[a_id "content"]
               [div ~a:[a_id div_id]
                  ((h1 [pcdata page_ttl]) :: ctnt)];

             div ~a:[a_id "footer"]
               [
                 (div ~a:[a_class ["copyright"]]
                    [
                      pcdata (s_ "(C) Copyright 2010, ");
                      ocamlcore_link;
                      pcdata ", ";
                      janest_link
                    ]);

                 (div ~a:[a_class ["sponsors"]]
                    [pcdata (s_ "Sponsors ");
                     ocamlcore_logo; 
                     janest_logo]);

                 (div ~a:[a_class ["links"]]
                    [a about sp [pcdata (s_ "About this website")] ()]);
               ]]])

let template ~ctxt ~sp ?extra_headers ~title ~div_id ctnt =
  Session.action_box ctxt sp
  >>= fun session_box ->
  return 
    (template_skeleton 
       ~sp ?extra_headers ~title ~div_id 
       session_box 
       ctnt)
