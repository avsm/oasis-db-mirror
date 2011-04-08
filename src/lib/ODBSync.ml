
(** Synchronization of a filesystem tree.
  
    This synchronization use two root files that helps to synchronize the whole
    hierarchy. These files are built in order to minimize the number of HTTP request
    to get them and the amount of data to download.

    The file sync.sexp describes using a list of S-expression what file have
    been added or removed. Each file added comes with its digest/size. This file can
    only grow or the revision number of sync-meta.sexp should be increased.

    @author Sylvain Le Gall
  *)

open Lwt
open Sexplib
open OASISUtils
open ODBGettext
open ODBMessage
open ExtLib
open FileUtilExt
open ODBFilesystem

TYPE_CONV_PATH "ODBSync"

module FS = ODBFilesystem

type digest = Digest.t

let sexp_of_digest d = 
  Conv.sexp_of_string (Digest.to_hex d)

let digest_of_sexp s = 
  let str = 
    Conv.string_of_sexp s
  in
  let str' =
    assert(String.length str mod 2 = 0);
    String.make ((String.length str) / 2) '\000'
  in
  let code = Char.code in

  let hex_val c =
    match c with 
      | '0'..'9' -> (code c) - (code '0')
      | 'A'..'F' -> (code c) - (code 'A') + 10
      | 'a'..'f' -> (code c) - (code 'a') + 10
      | c ->
          failwithf2 
            (f_ "Unknown hexadecimal digit '%c' in '%s'")
            c str
  in

    for i = 0 to (String.length str') - 1 do 
      str'.[i] <- (Char.chr (hex_val str.[2*i] * 16 + hex_val str.[2*i+1]))
    done;
    str'


type host_filename = string 

(* We dump/load host filename using an OS-independent 
 * format (UNIX) that is converted on the fly when loading
 *)

let host_filename_of_sexp s = 
  let str = Conv.string_of_sexp s in
  let lst = String.nsplit str "/" in
    FilePath.make_filename lst

let rec explode_filename fn =
  let rec explode fn = 
    if FilePath.is_current fn then
      []
    else
      FilePath.basename fn :: explode (FilePath.dirname fn)
  in
    List.rev (explode fn)

let sexp_of_host_filename fn = 
  let str =
    String.concat "/" (explode_filename fn)
  in
    Conv.sexp_of_string str

type file_size = int64 with sexp

type meta_t = 
    {
      sync_meta_rev:    int;
      sync_meta_size:   int64;
      sync_meta_digest: digest;
    }
      with sexp

(**/**)
type v_meta_t = 
    [ `V1 of meta_t ]
      with sexp

let meta_upgrade ~ctxt =
  function
    | `V1 m -> return m
(**/**)

type entry_t = 
  | Add of host_filename * digest * file_size
  | Rm of host_filename
      with sexp

(**/**)
type v_entry_t =
   [ `V1 of entry_t ]
      with sexp

let entry_upgrade ~ctxt = 
  function
    | `V1 e -> return e
(**/**)

module MapString = Map.Make(String)

type t =
    {
      sync_rev:          int;
      sync_size:         Int64.t;
      sync_fs:           FS.std_rw;
      sync_entries:      entry_t list;
      sync_entries_old:  entry_t list;
      sync_map:          (Digest.t * file_size) MapString.t;
      sync_ctxt:         ODBContext.t;
    }

let norm_fn fn =
  FilePath.reduce ~no_symlink:true fn

let id_fn t ?digest fn = 
  t.sync_fs#stat fn
  >>= fun st ->
  return st.Unix.LargeFile.st_size
  >>= fun sz ->
  begin
    match digest with 
      | Some d -> 
          return d
      | None ->
          t.sync_fs#digest fn
  end
  >|= fun digest ->
  digest, sz

let id_fn_ext fn = 
  LwtExt.IO.digest fn
  >>= fun digest ->
  try 
    return (digest, (Unix.LargeFile.stat fn).Unix.LargeFile.st_size)
  with e ->
    fail e

(** Add a file
  *)
let add fn t =
  let fn = norm_fn fn in

  let t' (fn, digest, sz) = 
    {t with
         sync_entries = 
           (Add (fn, digest, sz)) :: t.sync_entries;
         sync_map = 
           MapString.add fn (digest, sz) t.sync_map}
  in
    id_fn t fn 
    >|= fun (digest, sz) ->
    let id = (fn, digest, sz)
    in
      try 
        let reg_digest, reg_sz = 
          MapString.find fn t.sync_map 
        in
          if reg_digest <> digest || reg_sz <> sz then
            t' id
          else
            t
      with Not_found ->
        t' id

(** Remove a file 
  *)
let remove fn t =
  let fn = norm_fn fn in

    if MapString.mem fn t.sync_map then 
      {t with 
           sync_entries = 
             (Rm fn) :: t.sync_entries;
           sync_map =
             MapString.remove fn t.sync_map}
    else
      t

(** Filenames of log and log-version
  *)
let fn_meta = "sync-meta.sexp"
let fn_sync = "sync.sexp"

(** Dump the datastructure to disc 
  *)
let dump t =
  let dump_entries chn cnt e = 
    let str = 
      Sexp.to_string_mach
        (sexp_of_v_entry_t (`V1 e))
    in
      Lwt_io.write_line chn str
      >|= fun () -> 
      cnt + 1
  in
  let ctxt = t.sync_ctxt in

  let old_e = t.sync_entries_old in

  let entries = 
    let rec find_unwritten_entries acc new_e =
      if new_e = old_e then
        acc
      else
        begin
          match new_e with 
            | hd :: tl ->
                find_unwritten_entries (hd :: acc) tl 
            | [] ->
                raise Not_found
        end
    in
      try 
        return (find_unwritten_entries [] t.sync_entries)
      with Not_found ->
        fail 
          (Failure 
             (s_ "Unable to find new entries for sync.sexp"))
  in

    entries
    >>= fun entries ->
    with_file_out t.sync_fs
      ~flags:[Unix.O_WRONLY; Unix.O_CREAT; Unix.O_APPEND; 
              Unix.O_NONBLOCK]
      fn_sync
      (fun chn ->
         Lwt_list.fold_left_s (dump_entries chn) 0 entries)
    >>= fun cnt ->
    debug ~ctxt (f_ "Added %d entries to file '%s'") cnt fn_sync
    >>= fun () ->
    id_fn t fn_sync
    >>= fun (digest, sz) ->
    with_file_out t.sync_fs fn_meta
      (LwtExt.IO.sexp_dump_chn ~ctxt 
         sexp_of_v_meta_t
         (fun m -> `V1 m)
         ~fn:fn_meta
          {
            sync_meta_rev    = t.sync_rev;
            sync_meta_size   = sz;
            sync_meta_digest = digest;
          })
    >|= fun () ->
    {t with 
         sync_rev         = t.sync_rev;
         sync_size        = sz;
         sync_entries_old = t.sync_entries}


(** Load datastructure from disc
  *)
let load t = 
  let ctxt = t.sync_ctxt in
    t.sync_fs#file_exists fn_meta 
    >>= fun fn_meta_exists ->
    t.sync_fs#file_exists fn_sync
    >>= fun fn_exists ->
    if fn_meta_exists && fn_exists then
      begin
        with_file_in t.sync_fs fn_meta
          (LwtExt.IO.sexp_load_chn ~ctxt ~fn:fn_meta
             v_meta_t_of_sexp meta_upgrade)
        >>= fun meta ->

        id_fn t fn_sync
        >>= fun (fn_digest, fn_sz) ->

        begin
          let failwith fmt = 
            Printf.ksprintf
              (fun s -> Failure s)
              fmt
          in
            (* Check consistency of the file sync.sexp *)
            if fn_sz <> meta.sync_meta_size then
              fail 
                (failwith 
                   (f_ "Size mismatch for %s (%Ld <> %Ld)") 
                   fn_sync fn_sz meta.sync_meta_size)
            else if fn_digest <> meta.sync_meta_digest then
              fail 
                (failwith 
                   (f_ "Checksum mismatch for %s (%s <> %s)") 
                   fn_sync
                   (Digest.to_hex fn_digest)
                   (Digest.to_hex meta.sync_meta_digest))
            else
              return ()
        end
        >>= fun () ->

        begin
          let rebuild cont sexp = 
            entry_upgrade ~ctxt (v_entry_t_of_sexp sexp)
            >>= fun entry ->
            let f_sync_map =
              match entry with 
                | Add (fn, digest, sz) ->
                    MapString.add fn (digest, sz)
                | Rm fn ->
                    MapString.remove fn 
            in
              cont >|= fun t ->
              {t with 
                   sync_map = f_sync_map t.sync_map;
                   sync_entries = entry :: t.sync_entries}
          in
          let init = 
            return t 
          in
            with_file_in t.sync_fs fn_sync
              (LwtExt.IO.with_file_content_chn ~fn:fn_sync)
            >>= fun str ->
            Sexp.scan_fold_sexps
              ~f:rebuild
              ~init
              (Lexing.from_string str)
            >|= fun t ->
            {t with 
                 sync_rev         = meta.sync_meta_rev;
                 sync_size        = meta.sync_meta_size;
                 sync_entries_old = t.sync_entries}
        end
      end
    else
      begin
        return t
      end

(** Create the datastructure and load it from disc. If there is no datastructure
    on disc, create an empty one.
  *)
let create ~ctxt fs = 
  let res = 
    {
      sync_rev         = 0;
      sync_size        = -1L;
      sync_fs          = fs;
      sync_entries     = [];
      sync_entries_old = [];
      sync_map         = MapString.empty;
      sync_ctxt        = ctxt;
    }
  in
    load res 
    >>= fun res ->
    dump res
    >|= fun res ->
    res

(** Set the appropriate watch on filesystem
  *)
let autoupdate rsync = 
  let watcher fn fse =
    if fn <> fn_sync && fn <> fn_meta then
      begin
        let sync = !rsync in
          sync.sync_fs#is_directory fn
          >>= fun is_dir ->
          if not is_dir then 
            begin
              begin
                match fse with 
                  | FSCreated ->
                      add fn sync
                  | FSDeleted ->
                      return (remove fn sync)
                  | FSChanged ->
                      return sync
                  | FSMovedTo fn' ->
                      add fn' sync >|= remove fn 
                  | FSCopiedFrom fn' ->
                      add fn sync
              end
              >>= 
              dump 
              >>= fun sync ->
              return (rsync := sync)
            end
          else
            return ()
      end
    else
      return ()
  in
    !rsync.sync_fs#watch_add watcher

(** Update the sync datastructure with existing data on disc
  *)
let scan rsync =
  FS.fold
    (fun fne acc ->
       match fne with 
         | File fn when fn <> fn_sync && fn <> fn_meta ->
             return (SetString.add fn acc)
         | _ ->
             return acc)
    !rsync.sync_fs "" SetString.empty
  >>= fun existing_fn ->
  begin
    let sync = !rsync in

    let sync_fn =
      MapString.fold
        (fun fn _ acc ->
           SetString.add fn acc)
        sync.sync_map
        SetString.empty
    in
    let deletes = 
      SetString.diff sync_fn existing_fn
    in
    let adds =
      SetString.diff existing_fn sync_fn
    in
    let sync = 
      SetString.fold remove deletes sync
    in
      SetString.fold 
        (fun fn sync_lwt -> 
           sync_lwt >>= add fn)
        adds (return sync)
      >>= 
      dump 
      >>= fun sync ->
      return (rsync := sync)
  end

class remote sync uri =
object (self)

  inherit (FS.std_ro sync.sync_fs#root) as super

  val uri   = uri
  val mutable sync  = sync
  val mutable online = SetString.empty

  method ctxt = sync.sync_ctxt
  method cache = sync.sync_fs

  (** [url_concat url path] Concatenates a relative [path] onto an absolute
    * [url] 
    *)
  method private url_concat url tl = 
    (* TODO: cover more case  of URL concat *)
    if String.ends_with url "/" then
      url^tl
    else
      url^"/"^tl

  (** Take care of creating curl socket and closing it
    *)
  method private with_curl f = 
    (* Generic init of curl *)
    let c = 
      Curl.init () 
    in
    let () = 
      Curl.set_failonerror c true
    in
      finalize 
        (fun () -> 
           f c)
        (fun () -> 
           Curl.cleanup c;
           return ())

  (** Download an URI to a file using its channel. Use the position
    * of the channel to resume download.
    *)
  method private download_chn url fn chn = 
    let ctxt = self#ctxt in

    let curl_write fn chn d = 
      output_string chn d;
      String.length d
    in

    let download_curl c = 
      try 
        (* Resume download *)
        Curl.set_url c url;
        Curl.set_writefunction c (curl_write fn chn);
        Curl.set_resumefromlarge c (LargeFile.pos_out chn);
        Curl.perform c;
        return ()
      with 
        | Curl.CurlException(Curl.CURLE_HTTP_NOT_FOUND, _, _) ->
            fail
              (Failure
                 (Printf.sprintf
                    (f_ "URL not found '%s' url to download file '%s'")
                    url fn))
        | e ->
            fail e 
    in

      debug ~ctxt "Downloading '%s' to '%s'" url fn
      >>= fun () ->
      self#with_curl download_curl
      >>= fun () ->
      debug ~ctxt "Download of '%s' to '%s' completed" url fn


  (** Same as [download_chn] but open the file *)
  method private download_fn url fn =
    with_file_out self#cache fn
      (fun _ ->
         (* TODO: use the chn from with_file_out *) 
         let chn = 
           open_out (self#cache#rebase fn)
         in
           finalize
             (fun () -> self#download_chn url fn chn)
             (fun () -> return (close_out chn)))
           

  (** Check if the digest of give file is ok
    *)
  method private digest_ok ?(trust_digest=false) fn = 
    self#cache#file_exists fn
    >>= fun exists ->
    if exists then
      begin
        try 
          let (exp_digest, exp_sz) = 
            MapString.find fn sync.sync_map 
          in
          let digest = 
            if trust_digest then 
              Some exp_digest 
            else
              None
          in
            id_fn ?digest sync fn
            >|= fun (digest, sz) ->
            digest = exp_digest && sz = exp_sz
        with Not_found ->
          fail 
            (Failure 
               (Printf.sprintf 
                  (f_ "File '%s' is not part of the synchronization data")
                  fn))
      end
    else
      begin
        return false
      end

  (** Compute the host filename on disk, of a repository filename. It also 
    * makes sure that digest/size match expectation otherwise download it
    * from repository
    *)
  method private get ?(trust_digest=false) fn = 
      self#digest_ok ~trust_digest fn 
      >>= fun ok ->
      begin
        if not ok then
          begin
            let url = 
              self#url_concat 
                uri 
                (String.concat "/" (explode_filename fn))
            in
              self#cache#mkdir 
                ~ignore_exist:true 
                (FilePath.dirname fn)
                0o755
              >>= fun () ->
              self#download_fn url fn
              >>= fun () ->
              self#digest_ok fn
              >>= fun ok ->
              if ok then 
                return ()
              else
                fail
                  (Failure
                     (Printf.sprintf
                        (f_ "Downloading file '%s' from '%s' doesn't give \
                             the right checksum, update and try again.")
                        fn url))
          end
        else
          return ()
      end

  (* Remove empty directory *)
  method private clean_empty_dir =
    let rec one_pass () = 
      fold 
        (fun e acc ->
           match e with
             | PostDir dn ->
                 self#cache#readdir dn 
                 >>= 
                 begin
                   function 
                     | [||] -> 
                         info ~ctxt:self#ctxt
                           (f_ "Directory %s is empty")
                           dn
                         >>= fun () ->
                         return (dn :: acc)
                     | _   -> 
                         return acc
                 end
             | _ ->
                 return acc)
        self#cache ""
        []
      >>= 
        function 
          | [] ->
              return ()
          | lst ->
              self#cache#rm ~recurse:true lst
              >>=
              one_pass
    in
      one_pass ()

  method clean_file_filter filter =
    fold
      (fun e lst ->
         match e with 
           | File fn ->
               if fn <> fn_sync && fn <> fn_meta then 
                 begin
                   filter fn
                   >>= fun ok ->
                   if not ok then 
                     info ~ctxt:self#ctxt 
                       (f_ "File %s doesn't meet clean filter criteria")
                       fn
                     >>= fun () ->
                     return (fn :: lst)
                   else
                     return lst
                 end
               else
                 begin
                   return lst
                 end
           | _ ->
               return lst)
      self#cache ""
      []
    >>=
    self#cache#rm 

  (* Remove files that don't match their digest *)
  method private clean_file_digest = 
    self#clean_file_filter 
      (self#digest_ok ~trust_digest:false)

  (* Remove files that are not in the synchronization data set *)
  method private clean_extra_file =
    self#clean_file_filter
      (fun fn ->
         return (MapString.mem fn sync.sync_map))

  (* Remove files that are set online *)
  method private clean_online_file =
    self#clean_file_filter 
      (fun fn ->
         return (not (SetString.mem fn online)))

  (* Clean the cache file system of all un-needed files *)
  method repair =
    self#clean_online_file
    >>= fun () ->
    self#clean_extra_file
    >>= fun () ->
    self#clean_empty_dir

  (* Set a file to be used online only, i.e. not in the cache *)
  method online_set fn =
    online <- SetString.add fn online

  (* Update the synchronization data, downloading remote data. *)
  method update = 
    let ctxt = self#ctxt in
    let to_url fn = self#url_concat uri (FilePath.basename fn) in
    let url_meta = to_url fn_meta in
    let url_sync = to_url fn_sync in

    (* Download sync-meta.sexp *)
    let fn_meta_tmp, chn_meta_tmp = 
      Filename.open_temp_file "oasis-db-sync-meta-" ".sexp"
    in
    let fn_tmp, chn_tmp  = 
      Filename.open_temp_file "oasis-db-sync-" ".sexp"
    in

    let clean () = 
      let safe_close chn = 
        try close_out chn with _ -> ()
      in
        safe_close chn_meta_tmp;
        safe_close chn_tmp;
        rm [fn_meta_tmp; fn_tmp]
        >|= ignore
    in

    let check_sync_tmp meta fn_tmp = 
      id_fn_ext fn_tmp 
      >|= fun (digest, sz) ->
      (* Check downloaded data *)
      if meta.sync_meta_size = sz && meta.sync_meta_digest = digest then
        true, ""
      else if meta.sync_meta_size <> sz && meta.sync_meta_digest <> digest then
        false, 
        Printf.sprintf
          (f_ "size: %Ld <> %Ld; digest: %s <> %s")
          meta.sync_meta_size sz
          (Digest.to_hex meta.sync_meta_digest)
          (Digest.to_hex digest)
      else if meta.sync_meta_size <> sz then
        false, 
        Printf.sprintf
          (f_ "size: %Ld <> %Ld")
          meta.sync_meta_size sz
      else 
        false,
        Printf.sprintf
          (f_ "digest: %s <> %s")
          (Digest.to_hex meta.sync_meta_digest)
          (Digest.to_hex digest)
    in

      finalize
        (fun () -> 
           info ~ctxt
             (f_ "Download meta synchronization data '%s'")
             url_meta;
           >>= fun () ->
           self#download_chn url_meta fn_meta_tmp chn_meta_tmp
           >>= fun () ->
           return (close_out chn_meta_tmp)
           >>= fun () ->
           LwtExt.IO.sexp_load ~ctxt
             v_meta_t_of_sexp meta_upgrade
             fn_meta_tmp
           >>= fun meta_tmp ->

           info ~ctxt
             (f_ "Download synchronization data '%s'")
             url_sync
           >>= fun () -> 
           self#download_chn url_sync fn_tmp chn_tmp
           >>= fun () ->
           return (close_out chn_tmp)
           >>= fun () ->
           check_sync_tmp meta_tmp fn_tmp
           >>= fun (sync_ok, reason) ->
           begin
             if sync_ok then
               info ~ctxt 
                 (f_ "Download of '%s' successful.") url_sync
             else
               fail
                 (Failure 
                    (Printf.sprintf
                       (f_ "Download of '%s' failed (%s).")
                       url_sync reason))
           end
           >>= fun () ->

           (* We reach this point, all files should be valid. Copy them to their
            * final destination 
            *)
           Lwt.join
             [
               cp_ext fn_meta_tmp self#cache fn_meta;
               cp_ext fn_tmp self#cache fn_sync;
             ])

        (* Always clean at the end *)
        clean

      >>= fun () -> 
      (* Reload synchronization data *)
      load sync
      >>= fun sync' ->
      begin
        sync <- sync';
        (* Fix obvious problem in the filesystem tree *)
        self#repair
      end

  (** Override of std_ro methods *)

  method file_exists fn =
    let fn = norm_fn fn in
      if fn = "" || fn = FilePath.current_dir then
        return true
      else if MapString.mem fn sync.sync_map then
        return true
      else
        (* Maybe this is directory *)
        self#is_directory fn

  method is_directory fn =
    let fn = norm_fn fn in
    let res = 
      MapString.fold
        (fun fn' _ acc ->
           acc || fn = FilePath.dirname fn')
        sync.sync_map 
        false
    in
      return res

  method open_in fn =
    self#get fn
    >>= fun () ->
    sync.sync_fs#open_in fn

  method stat fn =
    self#get fn
    >>= fun () ->
    super#stat fn

  method readdir dn =
    let dn = norm_fn dn in
    let res =
      MapString.fold
        (fun fn _ acc ->
           if FilePath.dirname fn = dn then
             (FilePath.basename fn) :: acc
           else
             acc)
        sync.sync_map
        []
    in
      return (Array.of_list res)


end

(*
  method private filter_sync_method t fn = 
    match t.sync_method with 
      | `Full ->
          true

      | `Cached ->
          (* We only synchronize important data: _oasis and 
           * storage.sexp 
           *)
          begin
            match FilePath.basename fn with 
              | "storage.sexp"
              | "_oasis" -> 
                  true

              | _ ->
                  false
          end

    (* If we change sync method, there should be some extra files
     * all around the FS, remove them
     *)
    begin
      if remove_extra then
        FileUtilExt.fold
          (fun e lst ->
             match e with 
               | FileUtilExt.File fn ->
                   begin
                     let rel_fn = 
                       relative_fn t.sync_cache_dir fn 
                     in
                     let lst' =
                       if not (filter_sync_method t rel_fn) then
                         fn :: lst
                       else
                         lst
                     in
                       return lst'
                   end

               | _ ->
                   return lst)
          t.sync_cache_dir 
          []
        >>= 
        FileUtilExt.rm 
        >|= ignore
      else
        return ()
 *)
