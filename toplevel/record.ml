(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, * CNRS-Ecole Polytechnique-INRIA Futurs-Universite Paris Sud *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

(* $Id$ *)

open Pp
open Util
open Names
open Libnames
open Nameops
open Term
open Termops
open Environ
open Declarations
open Entries
open Declare
open Nametab
open Constrintern
open Command
open Inductive
open Safe_typing
open Decl_kinds
open Indtypes
open Type_errors
open Topconstr

(********** definition d'un record (structure) **************)

let interp_evars evdref env ?(impls=([],[])) k typ =
  let typ' = intern_gen true ~impls (Evd.evars_of !evdref) env typ in
  let imps = Implicit_quantifiers.implicits_of_rawterm typ' in
    imps, Pretyping.Default.understand_tcc_evars evdref env k typ'

let mk_interning_data env na impls typ =
  let impl = Impargs.compute_implicits_with_manual env typ (Impargs.is_implicit_args()) impls
  in (out_name na, (Constrintern.Method, [], impl, Notation.compute_arguments_scope typ))
    
let interp_fields_evars isevars env l =
  List.fold_left
    (fun (env, uimpls, params, impls) ((loc, i), b, t) ->
      let impl, t' = interp_evars isevars env ~impls Pretyping.IsType t in
      let b' = Option.map (fun x -> snd (interp_evars isevars env ~impls (Pretyping.OfType (Some t')) x)) b in
      let data = mk_interning_data env i impl t' in
      let d = (i,b',t') in
	(push_rel d env, impl :: uimpls, d::params, ([], data :: snd impls)))
    (env, [], [], ([], [])) l    

let binder_of_decl = function
  | Vernacexpr.AssumExpr(n,t) -> (n,None,t)
  | Vernacexpr.DefExpr(n,c,t) -> (n,Some c, match t with Some c -> c | None -> CHole (fst n, None))

let binders_of_decls = List.map binder_of_decl

let typecheck_params_and_fields id t ps fs =
  let env0 = Global.env () in
  let (env1,newps), imps = interp_context Evd.empty env0 ps in
  let fullarity = it_mkProd_or_LetIn t newps in
  let env_ar = push_rel_context newps (push_rel (Name id,None,fullarity) env0) in
  let evars = ref (Evd.create_evar_defs Evd.empty) in
  let env2,impls,newfs,data =
    interp_fields_evars evars env_ar (binders_of_decls fs)
  in
  let newps = Evarutil.nf_rel_context_evar (Evd.evars_of !evars) newps in
  let newfs = Evarutil.nf_rel_context_evar (Evd.evars_of !evars) newfs in
  let ce t = Evarutil.check_evars env0 Evd.empty !evars t in
    List.iter (fun (n, b, t) -> Option.iter ce b; ce t) newps;
    List.iter (fun (n, b, t) -> Option.iter ce b; ce t) newfs;
    imps, newps, impls, newfs

let degenerate_decl (na,b,t) =
  let id = match na with
    | Name id -> id
    | Anonymous -> anomaly "Unnamed record variable" in 
  match b with
    | None -> (id, Entries.LocalAssum t)
    | Some b -> (id, Entries.LocalDef b)

type record_error =
  | MissingProj of identifier * identifier list
  | BadTypedProj of identifier * env * Type_errors.type_error

let warning_or_error coe indsp err =
  let st = match err with
    | MissingProj (fi,projs) ->
	let s,have = if List.length projs > 1 then "s","were" else "","was" in
        (str(string_of_id fi) ++
	   strbrk" cannot be defined because the projection" ++ str s ++ spc () ++
           prlist_with_sep pr_coma pr_id projs ++ spc () ++ str have ++ 
	   strbrk " not defined.")
    | BadTypedProj (fi,ctx,te) ->
	match te with
	  | ElimArity (_,_,_,_,Some (_,_,NonInformativeToInformative)) ->
              (pr_id fi ++ 
		strbrk" cannot be defined because it is informative and " ++
		Printer.pr_inductive (Global.env()) indsp ++
		strbrk " is not.")   
	  | ElimArity (_,_,_,_,Some (_,_,StrongEliminationOnNonSmallType)) ->
	      (pr_id fi ++ 
		strbrk" cannot be defined because it is large and " ++
		Printer.pr_inductive (Global.env()) indsp ++
		strbrk " is not.")
	  | _ -> 
              (pr_id fi ++ strbrk " cannot be defined because it is not typable.")
  in
  if coe then errorlabstrm "structure" st;
  Flags.if_verbose ppnl (hov 0 (str"Warning: " ++ st))

type field_status =
  | NoProjection of name
  | Projection of constr

exception NotDefinable of record_error

(* This replaces previous projection bodies in current projection *)
(* Undefined projs are collected and, at least one undefined proj occurs *)
(* in the body of current projection then the latter can not be defined *)
(* [c] is defined in ctxt [[params;fields]] and [l] is an instance of *)
(* [[fields]] defined in ctxt [[params;x:ind]] *)
let subst_projection fid l c =
  let lv = List.length l in
  let bad_projs = ref [] in
  let rec substrec depth c = match kind_of_term c with
    | Rel k ->
	(* We are in context [[params;fields;x:ind;...depth...]] *)
        if k <= depth+1 then 
	  c
        else if k-depth-1 <= lv then
	  match List.nth l (k-depth-2) with
	    | Projection t -> lift depth t
	    | NoProjection (Name id) -> bad_projs := id :: !bad_projs; mkRel k
	    | NoProjection Anonymous -> assert false
        else 
	  mkRel (k-lv)
    | _ -> map_constr_with_binders succ substrec depth c
  in
  let c' = lift 1 c in (* to get [c] defined in ctxt [[params;fields;x:ind]] *)
  let c'' = substrec 0 c' in
  if !bad_projs <> [] then 
    raise (NotDefinable (MissingProj (fid,List.rev !bad_projs)));
  c''

let instantiate_possibly_recursive_type indsp paramdecls fields =
  let subst = list_map_i (fun i _ -> mkRel i) 1 paramdecls in
  substl_rel_context (subst@[mkInd indsp]) fields

(* We build projections *)
let declare_projections indsp ?(kind=StructureComponent) ?name coers fieldimpls fields =
  let env = Global.env() in
  let (mib,mip) = Global.lookup_inductive indsp in
  let paramdecls = mib.mind_params_ctxt in
  let r = mkInd indsp in
  let rp = applist (r, extended_rel_list 0 paramdecls) in
  let paramargs = extended_rel_list 1 paramdecls in (*def in [[params;x:rp]]*)
  let x = match name with Some n -> Name n | None -> Termops.named_hd (Global.env()) r Anonymous in
  let fields = instantiate_possibly_recursive_type indsp paramdecls fields in
  let lifted_fields = lift_rel_context 1 fields in
  let (_,kinds,sp_projs,_) =
    list_fold_left3
      (fun (nfi,kinds,sp_projs,subst) coe (fi,optci,ti) impls ->
	let (sp_projs,subst) =
	  match fi with
	  | Anonymous ->
	      (None::sp_projs,NoProjection fi::subst)
	  | Name fid ->
            try
              let ccl = subst_projection fid subst ti in
	      let body = match optci with
              | Some ci -> subst_projection fid subst ci
              | None ->
	        (* [ccl] is defined in context [params;x:rp] *)
		(* [ccl'] is defined in context [params;x:rp;x:rp] *)
		let ccl' = liftn 1 2 ccl in
		let p = mkLambda (x, lift 1 rp, ccl') in
		let branch = it_mkLambda_or_LetIn (mkRel nfi) lifted_fields in
		let ci = Inductiveops.make_case_info env indsp LetStyle in
		mkCase (ci, p, mkRel 1, [|branch|]) in
	      let proj =
	        it_mkLambda_or_LetIn (mkLambda (x,rp,body)) paramdecls in
              let projtyp =
                it_mkProd_or_LetIn (mkProd (x,rp,ccl)) paramdecls in
	      let kn =
	        try
		  let cie = {
		    const_entry_body = proj;
                    const_entry_type = Some projtyp;
                    const_entry_opaque = false;
		    const_entry_boxed = Flags.boxed_definitions() } in
		  let k = (DefinitionEntry cie,IsDefinition kind) in
		  let kn = declare_internal_constant fid k in
		  Flags.if_verbose message (string_of_id fid ^" is defined");
		  kn
                with Type_errors.TypeError (ctx,te) ->
                  raise (NotDefinable (BadTypedProj (fid,ctx,te))) in
	      let refi = ConstRef kn in
	      let constr_fi = mkConst kn in
	      Impargs.maybe_declare_manual_implicits 
		false refi (Impargs.is_implicit_args()) impls;
	      if coe then begin
	        let cl = Class.class_of_global (IndRef indsp) in
	        Class.try_add_new_coercion_with_source refi Global cl
	      end;
	      let proj_args = (*Rel 1 refers to "x"*) paramargs@[mkRel 1] in
	      let constr_fip = applist (constr_fi,proj_args) in
	      (Some kn::sp_projs, Projection constr_fip::subst)
            with NotDefinable why ->
	      warning_or_error coe indsp why;
	      (None::sp_projs,NoProjection fi::subst) in
      (nfi-1,(optci=None)::kinds,sp_projs,subst))
      (List.length fields,[],[],[]) coers (List.rev fields) (List.rev fieldimpls)
  in (kinds,sp_projs)

let declare_structure id idbuild paramimpls params arity fieldimpls fields
    ?(kind=StructureComponent) ?name is_coe coers =
  let nparams = List.length params and nfields = List.length fields in
  let args = extended_rel_list nfields params in
  let ind = applist (mkRel (1+nparams+nfields), args) in
  let type_constructor = it_mkProd_or_LetIn ind fields in
  let mie_ind =
    { mind_entry_typename = id;
      mind_entry_arity = arity;
      mind_entry_consnames = [idbuild];
      mind_entry_lc = [type_constructor] } in
  let declare_as_coind =
    (* CoInd if recursive; otherwise Ind to have compat on _ind schemes *) 
    dependent (mkRel (nparams+1)) (it_mkProd_or_LetIn mkProp fields) in
  let mie =
    { mind_entry_params = List.map degenerate_decl params;
      mind_entry_record = true;
      mind_entry_finite = not declare_as_coind;
      mind_entry_inds = [mie_ind] } in
  let kn = Command.declare_mutual_with_eliminations true mie [(paramimpls,[])] in
  let rsp = (kn,0) in (* This is ind path of idstruc *)
  let kinds,sp_projs = declare_projections rsp ~kind ?name coers fieldimpls fields in
  let build = ConstructRef (rsp,1) in
    if is_coe then Class.try_add_new_coercion build Global;
    Recordops.declare_structure(rsp,idbuild,List.rev kinds,List.rev sp_projs);
    kn

(* [fs] corresponds to fields and [ps] to parameters; [coers] is a boolean 
   list telling if the corresponding fields must me declared as coercion *)
let definition_structure ((is_coe,(_,idstruc)),ps,cfs,idbuild,s) =
  let coers,fs = List.split cfs in
  let extract_name acc = function
      Vernacexpr.AssumExpr((_,Name id),_) -> id::acc
    | Vernacexpr.DefExpr ((_,Name id),_,_) -> id::acc
    | _ -> acc in
  let allnames =  idstruc::(List.fold_left extract_name [] fs) in
  if not (list_distinct allnames) then error "Two objects have the same name";
  (* Now, younger decl in params and fields is on top *)
  let implpars, params, implfs, fields = typecheck_params_and_fields idstruc (mkSort s) ps fs in
  let implfs = List.map 
    (fun impls -> implpars @ Impargs.lift_implicits (succ (List.length params)) impls) implfs in
    declare_structure idstruc idbuild implpars params (mkSort s) implfs fields is_coe coers
  
