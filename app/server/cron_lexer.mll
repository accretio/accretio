{

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


open Cron_parser
exception Eof

}

rule token = parse
  [ '*' ]                          { STAR }
| [ '/' ]                          { SLASH }
| [ '0' - '9' ]+ as lxm            { INT(int_of_string lxm) }
| [ ' ' ]                          { SPACE }
| [ '-' ]                          { DASH }
| [ ',' ]                          { COMMA }
| eof                              { EOF }
