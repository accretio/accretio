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

type step = unit with bin_io
type steps = step list with bin_io, default_value([])

type t = {

  uid : uid ;

  created_on : timestamp ;

  reference : string ;
  min_age_in_months : int ;
  max_age_in_months : int ;

  title : string ;
  description : string ;
  summary : string ;

  attachments : Object_message.attachments ;

  number_of_spots : int ;

  bookings : [ `Booking ] edges ;

} with vertex
  (
    {
      aliases = [ `String reference ] ;
      required = [ reference ; min_age_in_months ; max_age_in_months ; number_of_spots ; title ; description ] ;
      uniques = [ reference ] ;
    }
  )
