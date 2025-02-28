(** Deadlock analysis using data race detection. *)

open Prelude.Ana
open Analyses

module Mutex = MutexAnalysis

module Spec =
struct
  include Analyses.DefaultSpec

  let name () = "oslo"
  module MSpec = Mutex.Spec
  module D = MSpec.D
  module G = MSpec.G
  module C = MSpec.C

  let extra_var = Goblintutil.create_var (makeGlobalVar "__deadlock_variable" intType)
  let gate_var = Goblintutil.create_var (makeGlobalVar "__gatelock_variable" intType)

  let init marshal = MSpec.init marshal
  let finalize () = MSpec.finalize ()

  let sync = MSpec.sync

  (* transfer functions *)
  let assign ctx (lval:lval) (rval:exp) : D.t = MSpec.assign ctx lval rval
  let branch ctx (exp:exp) (tv:bool) : D.t = MSpec.branch ctx exp tv
  let body ctx (f:fundec) : D.t = MSpec.body ctx f
  let return ctx (exp:exp option) (f:fundec) : D.t =  MSpec.return ctx exp f
  let enter ctx (lval: lval option) (f:fundec) (args:exp list) : (D.t * D.t) list = MSpec.enter ctx lval f args
  let combine ctx (lval:lval option) fexp (f:fundec) (args:exp list) fc (au:D.t) : D.t = MSpec.combine ctx lval fexp f args fc au

  let fake_unlock = Goblintutil.create_var (makeGlobalVar "pthread_mutex_unlock" intType)

  let add_access may must tid = true
  let add_gatelock may must tid = true

  let special ctx (lval: lval option) (f:varinfo) (arglist:exp list) : D.t =
    let thread = Obj.obj (List.assoc "thread-id-location" ctx.presub) in
    let maylocks = Obj.obj (List.assoc "maylocks" ctx.presub) in
    match (LibraryFunctions.classify f.vname arglist, f.vname) with
    | `Lock (failing, rw, _), _ when add_access ctx.local maylocks thread ->
      if add_gatelock ctx.local maylocks thread then begin
        let nd = MSpec.special ctx None f [AddrOf (Var gate_var, NoOffset)] in
        let nd = MSpec.assign (swap_st ctx nd) (Var extra_var, NoOffset) one in
        let nd = MSpec.special (swap_st ctx nd) None fake_unlock [AddrOf (Var gate_var, NoOffset)] in
        MSpec.special (swap_st ctx nd) lval f arglist
      end else
        MSpec.assign ctx (Var extra_var, NoOffset) one
    | _ -> MSpec.special ctx lval f arglist

  let startstate v = MSpec.startstate v
  let threadenter ctx lval f args = MSpec.threadenter ctx lval f args
  let threadspawn ctx lval f args fctx = MSpec.threadspawn ctx lval f args fctx
  let exitstate  v = MSpec.exitstate  v
end

let _ =
  MCP.register_analysis ~dep:["thread-id-location";"maylocks"] (module Spec : MCPSpec)
