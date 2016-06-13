(*
 * Copyright (c) 2010-2015 Anil Madhavapeddy <anil@recoil.org>
 * Copyright (C) 2015      Thomas Gazagnaire <thomas@gazagnaire.org>
 *
 * Permission to use, copy, modify, and distribute this software for any
 * purpose with or without fee is hereby granted, provided that the above
 * copyright notice and this permission notice appear in all copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
 * WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
 * ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
 * WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
 * ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
 * OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
 *)

let log fmt = Format.printf ("Netif: " ^^ fmt ^^ "\n%!")

let (>>=) = Lwt.(>>=)
let (>|=) = Lwt.(>|=)

type +'a io = 'a Lwt.t
type id = string

type error = [
  | `Unknown of string
  | `Unimplemented
  | `Disconnected
]

type stats = {
  mutable rx_bytes : int64;
  mutable rx_pkts : int32;
  mutable tx_bytes : int64;
  mutable tx_pkts : int32;
}

type t = {
  id: id;
  mutable active: bool;
  mutable mac: Macaddr.t;
  stats : stats;
}

external solo5_net_mac: unit -> string = "stub_net_mac"
external solo5_net_read: Cstruct.buffer -> int -> int = "stub_net_read"
external solo5_net_write: Cstruct.buffer -> int -> int = "stub_net_write"

let devices = Hashtbl.create 1

let err e = Lwt.return (`Error e)
let fail fmt = Printf.ksprintf (fun str -> Lwt.fail (Failure str)) fmt
let ok x = Lwt.return (`Ok x)

let err_unknown u = err (`Unknown u)
let err_disconnected () = err `Disconnected

let err_permission_denied devname =
  let s = Printf.sprintf
      "Permission denied while opening the %s tun device. \n\
       Please re-run using sudo, and install the TuntapOSX \n\
       package if you are on MacOS X." devname
  in
  err_unknown s

let err_partial_write len' page =
  fail "tap: partial write (%d, expected %d)" len' page.Cstruct.len


let connect devname =
  match Macaddr.of_string (solo5_net_mac ()) with
  | None -> err_unknown "mac issue"
  | Some m -> 
     let mac = m in
     log "plugging into %s with mac %s" devname (Macaddr.to_string mac);
     let active = true in
     let t = {
         id=devname; active; mac;
         stats= { rx_bytes=0L;rx_pkts=0l; tx_bytes=0L; tx_pkts=0l } }
     in
     Hashtbl.add devices devname t;
     log "connect %s" devname;
     ok t

let disconnect t =
  log "disconnect %s" t.id;
  Lwt.return_unit

type macaddr = Macaddr.t
type page_aligned_buffer = Io_page.t
type buffer = Cstruct.t

let pp_error fmt = function
  | `Unknown message -> Format.fprintf fmt "undiagnosed error - %s" message
  | `Unimplemented   -> Format.fprintf fmt "operation not yet implemented"
  | `Disconnected    -> Format.fprintf fmt "device is disconnected"

let do_read b =
  Lwt.return (solo5_net_read b.Cstruct.buffer b.Cstruct.len)

(* Input a frame, and block if nothing is available *)
let rec read t page =
  let buf = Io_page.to_cstruct page in
  let process () =
    Lwt.catch (fun () ->
               do_read buf >>= function
        | (-1) -> Lwt.return `EAGAIN                 (* EAGAIN or EWOULDBLOCK *)
        | 0    -> err_disconnected ()                                  (* EOF *)
        | len ->
          t.stats.rx_pkts <- Int32.succ t.stats.rx_pkts;
          t.stats.rx_bytes <- Int64.add t.stats.rx_bytes (Int64.of_int len);
          let buf = Cstruct.sub buf 0 len in
          ok buf)
      (function
        | exn ->
          log "[read] error: %s, continuing" (Printexc.to_string exn);
          Lwt.return `Continue)
  in
  process () >>= function
  | `EAGAIN -> OS.Main.wait_for_work () >>= fun () -> read t page
  | `Error _ | `Continue | `Ok _ as r -> Lwt.return r

let safe_apply f x =
  Lwt.catch
    (fun () -> f x)
    (fun exn ->
       log "[listen] error while handling %s, continuing. bt: %s"
         (Printexc.to_string exn) (Printexc.get_backtrace ());
       Lwt.return_unit)

(* Loop and listen for packets permanently *)
(* this function has to be tail recursive, since it is called at the
   top level, otherwise memory of received packets and all reachable
   data is never claimed.  take care when modifying, here be dragons! *)
let rec listen t fn =
  match t.active with
  | true ->
    let page = Io_page.get 1 in
    let process () =
      read t page >|= function
      | `Continue -> ()
      | `Ok buf   -> 
         Lwt.async (fun () -> safe_apply fn buf)
      | `Error e  ->
        log "[listen] error, %a, terminating listen loop" pp_error e;
        t.active <- false
    in
    process () >>= fun () ->
    listen t fn
  | false -> Lwt.return_unit

let do_write page =
  Lwt.return (solo5_net_write page.Cstruct.buffer page.Cstruct.len)

(* Transmit a packet from an Io_page *)
let write t page =
  let open Cstruct in
  (* Unfortunately we peek inside the cstruct type here: *)
  (* Lwt_bytes.write t.dev page.buffer page.off page.len  *)
  do_write page >>= fun len' ->
  t.stats.tx_pkts <- Int32.succ t.stats.tx_pkts;
  t.stats.tx_bytes <- Int64.add t.stats.tx_bytes (Int64.of_int page.len);
  if len' <> page.len then err_partial_write len' page
  else Lwt.return_unit

(* TODO use writev: but do a copy for now *)
let writev t = function
  | []     -> Lwt.return_unit
  | [page] -> write t page
  | pages  ->
    let page = Io_page.(to_cstruct (get 1)) in
    let off = ref 0 in
    List.iter (fun p ->
        let len = Cstruct.len p in
        Cstruct.blit p 0 page !off len;
        off := !off + len;
      ) pages;
    let v = Cstruct.sub page 0 !off in
    write t v

let mac t = t.mac

let get_stats_counters t = t.stats

let reset_stats_counters t =
  t.stats.rx_bytes <- 0L;
  t.stats.rx_pkts  <- 0l;
  t.stats.tx_bytes <- 0L;
  t.stats.tx_pkts  <- 0l
