(*
 * Accretio is an API, a sandbox and a runtime for social playbooks
 *
 * Copyright (C) 2015 William Le Ferrand
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as
 * published by the Free Software Foundation, either version 3 of the
 * License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *)


open Lwt
open Bin_prot.Std

open Ys_default
open Ys_types
open Ys_uid

type transport_email =
  {
    offset : int ;
    message_id : string ;
  } with bin_io

type transport =
  | NoTransport
  | Email of transport_email with bin_io, default_value(NoTransport)

type interlocutor = Stage of string | Member of uid | CatchAll | Society of (uid * string) with bin_io

type strings = string list with bin_io, default_value([])

type action =
    Pending
  | RoutedToStage of string with bin_io, default_value(Pending)

type attachment =
  {
    filename : string ;
    content_type : string ;
    content : string ;
  } with bin_io

type attachments = attachment list with bin_io, default_value([])

let create_reference content =
  let hash = Digest.to_hex (Digest.string (Printf.sprintf "%Ld-%s-%d" (Ys_time.now ()) content (Random.int 100000))) in
  Printf.sprintf "<%s@accret.io>" hash

type t = {

  uid : uid ;

  created_on : timestamp ;

  (* society : uid ; what is this field about?? *)

  origin : interlocutor ;
  destination : interlocutor ;

  subject : string ;
  content : string ;

  transport : transport ;

  reference : string ;
  references : strings ;

  tags : strings ;

  action : action ;
  attachments : attachments ;

  raw : string ;

} with vertex
  (
    {
      aliases = [ `String reference ] ;
      required = [ origin ; content ; destination ; reference ] ;
      uniques = [ reference ] ;
    }
  )
