(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

let () =
  register_error_kind
    `Temporary
    ~id:"unix_error"
    ~title:"Unix error"
    ~description:"An unhandled unix exception"
    ~pp:Format.pp_print_string
    Data_encoding.(obj1 (req "msg" string))
    (function
      | Exn (Unix.Unix_error (err, fn, _)) ->
          Some ("Unix error in " ^ fn ^ ": " ^ Unix.error_message err)
      | _ -> None)
    (fun msg -> Exn (Failure msg))

let read_bytes ?(pos = 0) ?len fd buf =
  let len = match len with None -> Bytes.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then
      Lwt.return_unit
    else
      Lwt_unix.read fd buf pos len >>= function
      | 0 -> Lwt.fail End_of_file (* other endpoint cleanly closed its connection *)
      | nb_read -> inner (pos + nb_read) (len - nb_read)
  in
  inner pos len

let read_mbytes ?(pos=0) ?len fd buf =
  let len = match len with None -> MBytes.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then
      Lwt.return_unit
    else
      Lwt_bytes.read fd buf pos len >>= function
      | 0 -> Lwt.fail End_of_file (* other endpoint cleanly closed its connection *)
      | nb_read -> inner (pos + nb_read) (len - nb_read)
  in
  inner pos len

let write_mbytes ?(pos=0) ?len descr buf =
  let len = match len with None -> MBytes.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then
      Lwt.return_unit
    else
      Lwt_bytes.write descr buf pos len >>= function
      | 0 -> Lwt.fail End_of_file (* other endpoint cleanly closed its connection *)
      | nb_written -> inner (pos + nb_written) (len - nb_written) in
  inner pos len

let write_bytes ?(pos=0) ?len descr buf =
  let len = match len with None -> Bytes.length buf - pos | Some l -> l in
  let rec inner pos len =
    if len = 0 then
      Lwt.return_unit
    else
      Lwt_unix.write descr buf pos len >>= function
      | 0 -> Lwt.fail End_of_file (* other endpoint cleanly closed its connection *)
      | nb_written -> inner (pos + nb_written) (len - nb_written) in
  inner pos len

let (>>=) = Lwt.bind

let remove_dir dir =
  let rec remove dir =
    let files = Lwt_unix.files_of_directory dir in
    Lwt_stream.iter_s
      (fun file ->
         if file = "." || file = ".." then
           Lwt.return ()
         else begin
           let file = Filename.concat dir file in
           if Sys.is_directory file
           then remove file
           else Lwt_unix.unlink file
         end)
      files >>= fun () ->
    Lwt_unix.rmdir dir in
  if Sys.file_exists dir && Sys.is_directory dir then
    remove dir
  else
    Lwt.return ()

let rec create_dir ?(perm = 0o755) dir =
  Lwt_unix.file_exists dir >>= function
  | false ->
      create_dir (Filename.dirname dir) >>= fun () ->
      Lwt_unix.mkdir dir perm
  | true ->
      Lwt_unix.stat dir >>= function
      | { st_kind = S_DIR ; _ } -> Lwt.return_unit
      | _ -> Pervasives.failwith "Not a directory"

let create_file ?(perm = 0o644) name content =
  Lwt_unix.openfile name Unix.([O_TRUNC; O_CREAT; O_WRONLY]) perm >>= fun fd ->
  Lwt_unix.write_string fd content 0 (String.length content) >>= fun _ ->
  Lwt_unix.close fd

let read_file fn =
  Lwt_io.with_file fn ~mode:Input begin fun ch ->
    Lwt_io.read ch
  end



let safe_close fd =
  Lwt.catch
    (fun () -> Lwt_unix.close fd)
    (fun _ -> Lwt.return_unit)



let of_sockaddr = function
  | Unix.ADDR_UNIX _ -> None
  | Unix.ADDR_INET (addr, port) ->
      match Ipaddr_unix.of_inet_addr addr with
      | V4 addr -> Some (Ipaddr.v6_of_v4 addr, port)
      | V6 addr -> Some (addr, port)

let getaddrinfo ~passive ~node ~service =
  let open Lwt_unix in
  getaddrinfo node service
    ( AI_SOCKTYPE SOCK_STREAM ::
      (if passive then [AI_PASSIVE] else []) ) >>= fun addr ->
  let points =
    TzList.filter_map
      (fun { ai_addr ; _ } -> of_sockaddr ai_addr)
      addr in
  Lwt.return points

let getpass () =
  let open Unix in
  (* Turn echoing off and fail if we can't. *)
  let tio = tcgetattr stdin in
  let old_echo = tio.c_echo in
  let old_echonl = tio.c_echonl in
  tio.c_echo <- false ;
  tio.c_echonl <- true ;
  tcsetattr stdin TCSAFLUSH tio ;
  (* Read the passwd. *)
  let passwd = read_line () in
  (* Restore terminal. *)
  tio.c_echo <- old_echo ;
  tio.c_echonl <- old_echonl ;
  tcsetattr stdin TCSAFLUSH tio ;
  passwd

module Json = struct

  let to_root = function
    | `O ctns -> `O ctns
    | `A ctns -> `A ctns
    | `Null -> `O []
    | oth -> `A [ oth ]

  let write_file file json =
    let json = to_root json in
    protect begin fun () ->
      Lwt_io.with_file ~mode:Output file begin fun chan ->
        let str = Data_encoding.Json.to_string ~minify:false json in
        Lwt_io.write chan str >>= fun _ ->
        return ()
      end
    end

  let read_file file =
    protect begin fun () ->
      Lwt_io.with_file ~mode:Input file begin fun chan ->
        Lwt_io.read chan >>= fun str ->
        return (Ezjsonm.from_string str :> Data_encoding.json)
      end
    end

end

module Protocol = struct

  let name = "TEZOS_PROTOCOL"

  open Protocol

  let (//) = Filename.concat

  let to_file ~dir:dirname ?hash ?env_version modules =
    let config_file =
      Data_encoding.Json.construct
        Meta.encoding
        { hash ; expected_env_version = env_version ; modules } in
    Json.write_file (dirname // name) config_file

  let of_file ~dir:dirname =
    Json.read_file (dirname // name) >>=? fun json ->
    return (Data_encoding.Json.destruct Meta.encoding json)

  let find_component dirname module_name =
    let name_lowercase = String.uncapitalize_ascii module_name in
    let implementation = dirname // name_lowercase ^ ".ml" in
    let interface = implementation ^ "i" in
    match Sys.file_exists implementation, Sys.file_exists interface with
    | false, _ -> Pervasives.failwith @@ "Not such file: " ^ implementation
    | true, false ->
        read_file implementation >|= fun implementation ->
        { name = module_name; interface = None; implementation }
    | _ ->
        read_file interface >>= fun interface ->
        read_file implementation >|= fun implementation ->
        { name = module_name; interface = Some interface; implementation }

  let read_dir dir =
    of_file ~dir >>=? fun meta ->
    Lwt_list.map_p (find_component dir) meta.modules >>= fun components ->
    let expected_env =
      match meta.expected_env_version with
      | None -> V1
      | Some v -> v in
    let protocol = { expected_env ; components } in
    let hash =
      match meta.hash with
      | None -> hash protocol
      | Some hash -> hash in
    return (hash, protocol)

  open Lwt.Infix

  let create_files dir units =
    remove_dir dir >>= fun () ->
    create_dir dir >>= fun () ->
    Lwt_list.map_s
      (fun { name ; interface ; implementation } ->
         let name = String.lowercase_ascii name in
         let ml = dir // (name ^ ".ml") in
         let mli = dir // (name ^ ".mli") in
         create_file ml implementation >>= fun () ->
         match interface with
         | None -> Lwt.return [ml]
         | Some content ->
             create_file mli content >>= fun () ->
             Lwt.return [ mli ; ml ])
      units >>= fun files ->
    let files = List.concat files in
    Lwt.return files

  let write_dir dir ?hash (p: t) =
    create_files dir p.components >>= fun _files ->
    to_file
      ~dir
      ?hash
      ~env_version:p.expected_env
      (List.map (fun { name ; _ } -> String.capitalize_ascii name) p.components)

end

let with_tempdir name f =
  let base_dir = Filename.temp_file name "" in
  Lwt_unix.unlink base_dir >>= fun () ->
  Lwt_unix.mkdir base_dir 0o700 >>= fun () ->
  Lwt.finalize (fun () -> f base_dir) (fun () -> remove_dir base_dir)


module Socket = struct

  type addr =
    | Unix of string
    | Tcp of string * int

  let get_addrs host =
    try return (Array.to_list (Unix.gethostbyname host).h_addr_list)
    with Not_found -> failwith "Host %s not found" host

  let connect path =
    match path with
    | Unix path ->
        let addr = Lwt_unix.ADDR_UNIX path in
        let sock = Lwt_unix.socket PF_UNIX SOCK_STREAM 0 in
        Lwt_unix.connect sock addr >>= fun () ->
        return sock
    | Tcp (host, port) ->
        get_addrs host >>=? fun addrs ->
        let rec try_connect = function
          | [] -> failwith "could not resolve host '%s'" host
          | addr :: addrs ->
              Lwt.catch
                (fun () ->
                   let addr = Lwt_unix.ADDR_INET (addr, port) in
                   let sock = Lwt_unix.socket PF_INET SOCK_STREAM 0 in
                   Lwt_unix.connect sock addr >>= fun () ->
                   return sock)
                (fun _ -> try_connect addrs) in
        try_connect addrs

  let bind ?(backlog = 10) path =
    match path with
    | Unix path ->
        let addr = Lwt_unix.ADDR_UNIX path in
        let sock = Lwt_unix.socket PF_UNIX SOCK_STREAM 0 in
        Lwt_unix.bind sock addr >>= fun () ->
        Lwt_unix.listen sock backlog ;
        return sock
    | Tcp (host, port) ->
        get_addrs host >>=? fun addrs ->
        let rec try_bind = function
          | [] -> failwith "could not resolve host '%s'" host
          | addr :: addrs ->
              Lwt.catch
                (fun () ->
                   let addr = Lwt_unix.ADDR_INET (addr, port) in
                   let sock = Lwt_unix.socket PF_INET SOCK_STREAM 0 in
                   Lwt_unix.setsockopt sock SO_REUSEADDR true ;
                   Lwt_unix.bind sock addr >>= fun () ->
                   Lwt_unix.listen sock backlog ;
                   return sock)
                (fun _ -> try_bind addrs) in
        try_bind addrs

  type error +=
    | Encoding_error
    | Decoding_error

  let () =
    register_error_kind `Permanent
      ~id: "signer.encoding_error"
      ~title: "Encoding_error"
      ~description: "Error while encoding a remote signer message"
      ~pp: (fun ppf () ->
          Format.fprintf ppf "Could not encode a remote signer message")
      Data_encoding.empty
      (function Encoding_error -> Some () | _ -> None)
      (fun () -> Encoding_error) ;
    register_error_kind `Permanent
      ~id: "signer.decoding_error"
      ~title: "Decoding_error"
      ~description: "Error while decoding a remote signer message"
      ~pp: (fun ppf () ->
          Format.fprintf ppf "Could not decode a remote signer message")
      Data_encoding.empty
      (function Decoding_error -> Some () | _ -> None)
      (fun () -> Decoding_error)

  let message_len_size = 2

  let send fd encoding message =
    let encoded_message_len = Data_encoding.Binary.length encoding message in
    fail_unless
      (encoded_message_len < 1 lsl (message_len_size * 8))
      Encoding_error >>=? fun () ->
    (* len is the length of int16 plus the length of the message we want to send *)
    let len = message_len_size + encoded_message_len in
    let buf = MBytes.create len in
    match Data_encoding.Binary.write
            encoding message buf message_len_size encoded_message_len with
    | None ->
        fail Encoding_error
    | Some last ->
        fail_unless (last = len) Encoding_error >>=? fun () ->
        (* we set the beginning of the buf with the length of what is next *)
        MBytes.set_int16 buf 0 encoded_message_len ;
        write_mbytes fd buf >>= fun () ->
        return ()

  let recv fd encoding =
    let header_buf = MBytes.create message_len_size in
    read_mbytes ~len:message_len_size fd header_buf >>= fun () ->
    let len = MBytes.get_uint16 header_buf 0 in
    let buf = MBytes.create len in
    read_mbytes ~len fd buf >>= fun () ->
    match Data_encoding.Binary.read encoding buf 0 len with
    | None ->
        fail Decoding_error
    | Some (read_len, message) ->
        if read_len <> len then
          fail Decoding_error
        else
          return message

end
