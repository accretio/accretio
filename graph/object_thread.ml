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


open Bin_prot.Std
open Ys_default

open Ys_types
open Ys_uid

type content = Text of string | Image of uid with bin_io

type message =
  {
    author : uid ;
    timestamp : timestamp ;
    content : content ;
  } with bin_io

type messages = message list with bin_io, default_value ([])

(* the thread object **********************************************************)

type t = {

  uid : uid ;
  created_on : timestamp ;
  last_modified : timestamp ;

  owner : uid ;
  subject: string ;
  messages : messages ;
  number_of_messages : int ;

  context : [ `Cohort | `Playbook ] edges ;
  followers : [ `Member | `Follower ] edges ;

} with vertex
   (
    {
      required = [ owner ] ;
    }
   )
