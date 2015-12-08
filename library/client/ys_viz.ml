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

open Eliom_content.Html5
open Eliom_content.Html5.D

let render container graph =
  let svg = Js.Unsafe.fun_call (Js.Unsafe.variable "Viz") [| Js.Unsafe.inject (Js.string graph) |] in
  ignore_result (Lwt_js.yield () >>= function _ ->
      (To_dom.of_div container)##innerHTML <- svg ;
      return_unit) ;
