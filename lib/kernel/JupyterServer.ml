(* ocaml-jupyter --- An OCaml kernel for Jupyter

   Copyright (c) 2017 Akinori ABE

   Permission is hereby granted, free of charge, to any person obtaining a copy
   of this software and associated documentation files (the "Software"), to deal
   in the Software without restriction, including without limitation the rights
   to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
   copies of the Software, and to permit persons to whom the Software is
   furnished to do so, subject to the following conditions:

   The above copyright notice and this permission notice shall be included in all
   copies or substantial portions of the Software.

   THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
   IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
   FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
   AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
   LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
   OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
   SOFTWARE. *)

(** Kernel server *)

open Format
open Lwt.Infix

module M = JupyterMessage
module ShC = Jupyter.Content.Shell
module IoC = Jupyter.Content.Iopub

module Make
    (ShellChannel : JupyterChannelIntf.Shell)
    (IopubChannel : JupyterChannelIntf.Iopub)
    (StdinChannel : JupyterChannelIntf.Stdin)
    (Repl : module type of JupyterRepl.Process) =
struct
  type t =
    {
      repl : Repl.t;
      shell : ShellChannel.t;
      control : ShellChannel.t;
      iopub : IopubChannel.t;
      stdin : StdinChannel.t;

      mutable execution_count : int;
      mutable current_parent : ShellChannel.input option;
    }

  let create ~repl ~ctx info =
    let key = info.JupyterConnectionInfo.key in
    let shell =
      JupyterConnectionInfo.(make_address info info.shell_port)
      |> ShellChannel.create ?key ~ctx ~kind:ZMQ.Socket.router
    in
    let control =
      JupyterConnectionInfo.(make_address info info.control_port)
      |> ShellChannel.create ?key ~ctx ~kind:ZMQ.Socket.router
    in
    let iopub =
      JupyterConnectionInfo.(make_address info info.iopub_port)
      |> IopubChannel.create ?key ~ctx ~kind:ZMQ.Socket.pub
    in
    let stdin =
      JupyterConnectionInfo.(make_address info info.stdin_port)
      |> StdinChannel.create ?key ~ctx ~kind:ZMQ.Socket.router
    in
    {
      repl; shell; control; iopub; stdin;
      execution_count = 0;
      current_parent = None;
    }

  let close server =
    Lwt.join [
      Repl.close server.repl;
      ShellChannel.close server.shell;
      ShellChannel.close server.control;
      IopubChannel.close server.iopub;
      StdinChannel.close server.stdin;
    ]

  (** {2 IOPUB utility} *)

  let send_iopub server content =
    match server.current_parent with
    | Some parent -> IopubChannel.reply server.iopub ~parent content
    | None -> Lwt.return ()

  let send_iopub_stream server ~name text =
    send_iopub server IoC.(`Stream { name; text; })

  let send_iopub_status server execution_state =
    send_iopub server IoC.(`Status { execution_state; })

  let send_iopub_exec_input server code =
    let execution_count = server.execution_count in
    send_iopub server IoC.(`Execute_input { code; execution_count; })

  let send_iopub_exec_result ~klass server msg =
    let html =
      sprintf "<pre><span class=\"%s\">%s</span></pre>"
        klass (JupyterHtml.escape msg)
    in
    send_iopub server IoC.(`Execute_result {
        execution_count = server.execution_count;
        data = `Assoc ["text/html", `String html];
        metadata = `Assoc [];
      })

  (** {2 Execute request} *)

  let execute_request ~parent server (body : ShC.execute_request) =
    server.execution_count <- succ server.execution_count ;
    server.current_parent <- Some parent ;
    let code = body.ShC.code in
    let%lwt () = send_iopub_status server `Busy in
    let%lwt () = send_iopub_exec_input server code in
    let filename = sprintf "[%d]" server.execution_count in
    Repl.run server.repl ~filename code

  (** {2 Kernel info request} *)

  let kernel_info_request ~parent shell =
    ShC.(`Kernel_info_reply kernel_info_reply)
    |> ShellChannel.reply shell ~parent

  (** {2 Shutdown request} *)

  let shutdown_request ~parent shell body =
    ShC.(`Shutdown_reply body)
    |> ShellChannel.reply shell ~parent

  (** {2 Main routine} *)

  (** a thread capturing stdout and stderr from a REPL. *)
  let propagate_repl_to_iopub server =
    let strm = Repl.stream server.repl in
    let rec loop status =
      match%lwt Lwt_stream.get strm with
      | None -> Lwt.return_unit (* done *)
      | Some (`Iopub iopub) ->
        let%lwt () = send_iopub server iopub in
        loop status
      | Some (`Stdout s) ->
        let%lwt () = send_iopub_stream server ~name:`Stdout s in
        loop status
      | Some (`Stderr s) ->
        let%lwt () = send_iopub_stream server ~name:`Stderr s in
        loop status
      | Some (`Ok s) ->
        let%lwt () = send_iopub_exec_result ~klass:"ansi-black-fg" server s in
        loop status
      | Some (`Runtime_error s) | Some (`Compile_error s) ->
        let%lwt () = send_iopub_exec_result ~klass:"ansi-red-fg" server s in
        loop `Error
      | Some `Aborted -> loop `Abort (* Interrupted *)
      | Some `Prompt ->
        let%lwt () = send_iopub_status server `Idle in
        let%lwt () =
          match server.current_parent with
          | None -> Lwt.return_unit
          | Some parent ->
            ShC.(`Execute_reply {
                execution_count = server.execution_count;
                status;
              })
            |> ShellChannel.reply server.shell ~parent
        in
        loop `Ok (* Reset the current status to OK *)
    in
    loop `Ok

  (** a thread propagating IOPUB requests to a REPL process *)
  let propagate_iopub_to_repl server =
    let rec loop () =
      let%lwt req = IopubChannel.recv server.iopub in
      let%lwt () = Repl.send server.repl req.JupyterMessage.content in
      loop ()
    in
    loop ()

  let start_kernel server shell =
    let rec reply parent = function
      | `Shutdown_request body -> shutdown_request ~parent shell body
      | `Kernel_info_request -> kernel_info_request ~parent shell >>= loop
      | `Execute_request body -> execute_request ~parent server body >>= loop
      | `Inspect_request _
      | `Complete_request _
      | `Connect_request
      | `Comm_info_request _ ->
        JupyterLog.error "Unsupported request" ;
        loop ()
    and loop () =
      ShellChannel.recv shell >>= fun req -> reply req req.M.content
    in
    loop ()

  let start server =
    Lwt.choose [
      propagate_repl_to_iopub server;
      propagate_iopub_to_repl server;
      start_kernel server server.shell;
      start_kernel server server.control;
    ]
end