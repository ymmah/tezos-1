(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

type frozen_balance = {
  deposit : Tez_repr.t ;
  fees : Tez_repr.t ;
  rewards : Tez_repr.t ;
}

let frozen_balance_encoding =
  let open Data_encoding in
  conv
    (fun { deposit ; fees ; rewards } -> (deposit, fees, rewards))
    (fun (deposit, fees, rewards) -> { deposit ; fees ; rewards })
    (obj3
       (req "deposit" Tez_repr.encoding)
       (req "fees" Tez_repr.encoding)
       (req "rewards" Tez_repr.encoding))

type error +=
  | Non_delegatable_contract of Contract_repr.contract (* `Permanent *)
  | No_deletion of Signature.Public_key_hash.t (* `Permanent *)
  | Active_delegate (* `Temporary *)
  | Current_delegate (* `Temporary *)
  | Empty_delegate_account of Signature.Public_key_hash.t (* `Temporary *)
  | Balance_too_low_for_deposit of
      { delegate : Signature.Public_key_hash.t ;
        deposit : Tez_repr.t ;
        balance : Tez_repr.t } (* `Temporary *)

let () =
  register_error_kind
    `Permanent
    ~id:"contract.undelegatable_contract"
    ~title:"Non delegatable contract"
    ~description:"Tried to delegate an implicit contract \
                  or a non delegatable originated contract"
    ~pp:(fun ppf contract ->
        Format.fprintf ppf "Contract %a is not delegatable"
          Contract_repr.pp contract)
    Data_encoding.(obj1 (req "contract" Contract_repr.encoding))
    (function Non_delegatable_contract c -> Some c | _ -> None)
    (fun c -> Non_delegatable_contract c) ;
  register_error_kind
    `Permanent
    ~id:"delegate.no_deletion"
    ~title:"Forbidden delegate deletion"
    ~description:"Tried to unregister a delegate"
    ~pp:(fun ppf delegate ->
        Format.fprintf ppf "Delegate deletion is forbidden (%a)"
          Signature.Public_key_hash.pp delegate)
    Data_encoding.(obj1 (req "delegate" Signature.Public_key_hash.encoding))
    (function No_deletion c -> Some c | _ -> None)
    (fun c -> No_deletion c) ;
  register_error_kind
    `Temporary
    ~id:"delegate.already_active"
    ~title:"Delegate already active"
    ~description:"Useless delegate reactivation"
    ~pp:(fun ppf () ->
        Format.fprintf ppf
          "The delegate is still active, no need to refresh it")
    Data_encoding.empty
    (function Active_delegate -> Some () | _ -> None)
    (fun () -> Active_delegate) ;
  register_error_kind
    `Temporary
    ~id:"delegate.unchanged"
    ~title:"Unchanged delegated"
    ~description:"Contract already delegated to the given delegate"
    ~pp:(fun ppf () ->
        Format.fprintf ppf
          "The contract is already delegated to the same delegate")
    Data_encoding.empty
    (function Current_delegate -> Some () | _ -> None)
    (fun () -> Current_delegate) ;
  register_error_kind
    `Permanent
    ~id:"delegate.empty_delegate_account"
    ~title:"Empty delegate account"
    ~description:"Cannot register a delegate when its implicit account is empty"
    ~pp:(fun ppf delegate ->
        Format.fprintf ppf
          "Delegate registration is forbidden when the delegate
           implicit account is empty (%a)"
          Signature.Public_key_hash.pp delegate)
    Data_encoding.(obj1 (req "delegate" Signature.Public_key_hash.encoding))
    (function Empty_delegate_account c -> Some c | _ -> None)
    (fun c -> Empty_delegate_account c) ;
  register_error_kind
    `Temporary
    ~id:"delegate.balance_too_low_for_deposit"
    ~title:"Balance too low for deposit"
    ~description:"Cannot freeze deposit when the balance is too low"
    ~pp:(fun ppf (delegate, balance, deposit) ->
        Format.fprintf ppf
          "Delegate %a has a too low balance (%a) to deposit %a"
          Signature.Public_key_hash.pp delegate
          Tez_repr.pp balance
          Tez_repr.pp deposit)
    Data_encoding.
      (obj3
         (req "delegate" Signature.Public_key_hash.encoding)
         (req "balance" Tez_repr.encoding)
         (req "deposit" Tez_repr.encoding))
    (function Balance_too_low_for_deposit { delegate ; balance ; deposit } ->
       Some (delegate, balance, deposit) | _ -> None)
    (fun (delegate, balance, deposit) -> Balance_too_low_for_deposit { delegate ; balance ; deposit } )

let is_delegatable c contract =
  match Contract_repr.is_implicit contract with
  | Some _ ->
      return false
  | None ->
      Storage.Contract.Delegatable.mem c contract >>= return

let link c contract delegate balance =
  Roll_storage.Delegate.add_amount c delegate balance >>=? fun c ->
  match Contract_repr.is_originated contract with
  | None -> return c
  | Some h ->
      Storage.Contract.Delegated.add
        (c, Contract_repr.implicit_contract delegate) h >>= fun c ->
      return c

let unlink c contract balance =
  Storage.Contract.Delegate.get_option c contract >>=? function
  | None -> return c
  | Some delegate ->
      Roll_storage.Delegate.remove_amount c delegate balance >>=? fun c ->
      match Contract_repr.is_originated contract with
      | None -> return c
      | Some h ->
          Storage.Contract.Delegated.del
            (c, Contract_repr.implicit_contract delegate) h >>= fun c ->
          return c

let known c delegate =
  Storage.Contract.Manager.get_option
    c (Contract_repr.implicit_contract delegate) >>=? function
  | None | Some (Manager_repr.Hash _) -> return false
  | Some (Manager_repr.Public_key _) -> return true

(* A delegate is registered if its "implicit account"
   delegates to itself. *)
let registered c delegate =
  Storage.Contract.Delegate.mem
    c (Contract_repr.implicit_contract delegate)

let init ctxt contract delegate =
  Storage.Contract.Delegate.init ctxt contract delegate >>=? fun ctxt ->
  Storage.Contract.Balance.get ctxt contract >>=? fun balance ->
  link ctxt contract delegate balance

let get = Roll_storage.get_contract_delegate

let set_base c is_delegatable contract delegate =
  match delegate with
  | None -> begin
      match Contract_repr.is_implicit contract with
      | Some pkh ->
          fail (No_deletion pkh)
      | None ->
          is_delegatable c contract >>=? fun delegatable ->
          if delegatable then
            Storage.Contract.Balance.get c contract >>=? fun balance ->
            unlink c contract balance >>=? fun c ->
            Storage.Contract.Delegate.remove c contract >>= fun c ->
            return c
          else
            fail (Non_delegatable_contract contract)
    end
  | Some delegate ->
      known c delegate >>=? fun known_delegate ->
      registered c delegate >>= fun registered_delegate ->
      is_delegatable c contract >>=? fun delegatable ->
      let self_delegation =
        match Contract_repr.is_implicit contract with
        | Some pkh -> Signature.Public_key_hash.equal pkh delegate
        | None -> false in
      if not known_delegate || not (registered_delegate || self_delegation) then
        fail (Roll_storage.Unregistered_delegate delegate)
      else if not (delegatable || self_delegation) then
        fail (Non_delegatable_contract contract)
      else
        begin
          Storage.Contract.Delegate.get_option c contract >>=? function
          | Some current_delegate
            when Signature.Public_key_hash.equal delegate current_delegate ->
              if self_delegation then
                Storage.Contract.Inactive_delegate.mem c contract >>= function
                | true -> return ()
                | false -> fail Active_delegate
              else
                fail Current_delegate
          | None | Some _ -> return ()
        end >>=? fun () ->
        Storage.Contract.Balance.mem c contract >>= fun exists ->
        fail_when
          (self_delegation && not exists)
          (Empty_delegate_account delegate) >>=? fun () ->
        Storage.Contract.Balance.get c contract >>=? fun balance ->
        unlink c contract balance >>=? fun c ->
        Storage.Contract.Delegate.init_set c contract delegate >>= fun c ->
        link c contract delegate balance >>=? fun c ->
        begin
          if self_delegation then
            Storage.Delegates.add c delegate >>= fun c ->
            Roll_storage.Delegate.set_active c delegate >>=? fun c ->
            return c
          else
            return c
        end >>=? fun c ->
        return c

let set c contract delegate =
  set_base c is_delegatable contract delegate

let set_from_script c contract delegate =
  set_base c (fun _ _ -> return true) contract delegate

let remove ctxt contract =
  Storage.Contract.Balance.get ctxt contract >>=? fun balance ->
  unlink ctxt contract balance

let fold = Storage.Delegates.fold
let list = Storage.Delegates.elements

let delegated_contracts ctxt delegate =
  let contract = Contract_repr.implicit_contract delegate in
  Storage.Contract.Delegated.elements (ctxt, contract)

let get_frozen_deposit ctxt contract cycle =
  Storage.Contract.Frozen_deposits.get_option (ctxt, contract) cycle >>=? function
  | None -> return Tez_repr.zero
  | Some frozen -> return frozen

let credit_frozen_deposit ctxt contract cycle amount =
  get_frozen_deposit ctxt contract cycle >>=? fun old_amount ->
  Lwt.return Tez_repr.(old_amount +? amount) >>=? fun new_amount ->
  Storage.Contract.Frozen_deposits.init_set
    (ctxt, contract) cycle new_amount >>= fun ctxt ->
  return ctxt

let freeze_deposit ctxt delegate amount =
  let { Level_repr.cycle ; _ } = Level_storage.current ctxt in
  Roll_storage.Delegate.set_active ctxt delegate >>=? fun ctxt ->
  let contract = Contract_repr.implicit_contract delegate in
  Storage.Contract.Balance.get ctxt contract >>=? fun balance ->
  Lwt.return
    (record_trace (Balance_too_low_for_deposit { delegate; deposit = amount; balance })
       Tez_repr.(balance -? amount)) >>=? fun new_balance ->
  Storage.Contract.Balance.set ctxt contract new_balance >>=? fun ctxt ->
  credit_frozen_deposit ctxt contract cycle amount

let get_frozen_fees ctxt contract cycle =
  Storage.Contract.Frozen_fees.get_option (ctxt, contract) cycle >>=? function
  | None -> return Tez_repr.zero
  | Some frozen -> return frozen

let credit_frozen_fees ctxt contract cycle amount =
  get_frozen_fees ctxt contract cycle >>=? fun old_amount ->
  Lwt.return Tez_repr.(old_amount +? amount) >>=? fun new_amount ->
  Storage.Contract.Frozen_fees.init_set
    (ctxt, contract) cycle new_amount >>= fun ctxt ->
  return ctxt

let freeze_fees ctxt delegate amount =
  let { Level_repr.cycle ; _ } = Level_storage.current ctxt in
  let contract = Contract_repr.implicit_contract delegate in
  Roll_storage.Delegate.add_amount ctxt delegate amount >>=? fun ctxt ->
  credit_frozen_fees ctxt contract cycle amount

let burn_fees ctxt delegate cycle amount =
  let contract = Contract_repr.implicit_contract delegate in
  get_frozen_fees ctxt contract cycle >>=? fun old_amount ->
  begin
    match Tez_repr.(old_amount -? amount) with
    | Ok new_amount ->
        Roll_storage.Delegate.remove_amount
          ctxt delegate amount >>=? fun ctxt ->
        return (new_amount, ctxt)
    | Error _ ->
        Roll_storage.Delegate.remove_amount
          ctxt delegate old_amount >>=? fun ctxt ->
        return (Tez_repr.zero, ctxt)
  end >>=? fun (new_amount, ctxt) ->
  Storage.Contract.Frozen_fees.set (ctxt, contract) cycle new_amount


let get_frozen_rewards ctxt contract cycle =
  Storage.Contract.Frozen_rewards.get_option (ctxt, contract) cycle >>=? function
  | None -> return Tez_repr.zero
  | Some frozen -> return frozen

let credit_frozen_rewards ctxt contract cycle amount =
  get_frozen_rewards ctxt contract cycle >>=? fun old_amount ->
  Lwt.return Tez_repr.(old_amount +? amount) >>=? fun new_amount ->
  Storage.Contract.Frozen_rewards.init_set
    (ctxt, contract) cycle new_amount >>= fun ctxt ->
  return ctxt

let freeze_rewards ctxt delegate amount =
  let { Level_repr.cycle ; _ } = Level_storage.current ctxt in
  let contract = Contract_repr.implicit_contract delegate in
  credit_frozen_rewards ctxt contract cycle amount

let burn_rewards ctxt delegate cycle amount =
  let contract = Contract_repr.implicit_contract delegate in
  get_frozen_rewards ctxt contract cycle >>=? fun old_amount ->
  let new_amount =
    match Tez_repr.(old_amount -? amount) with
    | Error _ -> Tez_repr.zero
    | Ok new_amount -> new_amount in
  Storage.Contract.Frozen_rewards.set (ctxt, contract) cycle new_amount



let unfreeze ctxt delegate cycle =
  let contract = Contract_repr.implicit_contract delegate in
  get_frozen_deposit ctxt contract cycle >>=? fun deposit ->
  get_frozen_fees ctxt contract cycle >>=? fun fees ->
  get_frozen_rewards ctxt contract cycle >>=? fun rewards ->
  Storage.Contract.Balance.get ctxt contract >>=? fun balance ->
  Lwt.return Tez_repr.(balance +? deposit) >>=? fun balance ->
  Lwt.return Tez_repr.(balance +? fees) >>=? fun balance ->
  Lwt.return Tez_repr.(balance +? rewards) >>=? fun balance ->
  Storage.Contract.Balance.set ctxt contract balance >>=? fun ctxt ->
  Roll_storage.Delegate.add_amount ctxt delegate rewards >>=? fun ctxt ->
  Storage.Contract.Frozen_deposits.remove (ctxt, contract) cycle >>= fun ctxt ->
  Storage.Contract.Frozen_fees.remove (ctxt, contract) cycle >>= fun ctxt ->
  Storage.Contract.Frozen_rewards.remove (ctxt, contract) cycle >>= fun ctxt ->
  return ctxt

let cycle_end ctxt last_cycle unrevealed =
  let preserved = Constants_storage.preserved_cycles ctxt in
  begin
    match Cycle_repr.pred last_cycle with
    | None -> return ctxt
    | Some revealed_cycle ->
        List.fold_left
          (fun ctxt (u : Nonce_storage.unrevealed) ->
             ctxt >>=? fun ctxt ->
             burn_fees
               ctxt u.delegate revealed_cycle u.fees >>=? fun ctxt ->
             burn_rewards
               ctxt u.delegate revealed_cycle u.rewards >>=? fun ctxt ->
             return ctxt)
          (return ctxt) unrevealed
  end >>=? fun ctxt ->
  match Cycle_repr.sub last_cycle preserved with
  | None -> return ctxt
  | Some unfrozen_cycle ->
      fold ctxt
        ~init:(Ok ctxt)
        ~f:(fun delegate ctxt ->
            Lwt.return ctxt >>=? fun ctxt ->
            unfreeze ctxt delegate unfrozen_cycle >>=? fun ctxt ->
            Storage.Contract.Delegate_desactivation.get ctxt
              (Contract_repr.implicit_contract delegate) >>=? fun cycle ->
            if Cycle_repr.(cycle <= last_cycle) then
              Roll_storage.Delegate.set_inactive ctxt delegate
            else
              return ctxt)

let punish ctxt delegate cycle =
  let contract = Contract_repr.implicit_contract delegate in
  get_frozen_deposit ctxt contract cycle >>=? fun deposit ->
  get_frozen_fees ctxt contract cycle >>=? fun fees ->
  get_frozen_rewards ctxt contract cycle >>=? fun rewards ->
  Roll_storage.Delegate.remove_amount ctxt delegate deposit >>=? fun ctxt ->
  Roll_storage.Delegate.remove_amount ctxt delegate fees >>=? fun ctxt ->
  (* Rewards are not in the delegate balance yet... *)
  Storage.Contract.Frozen_deposits.remove (ctxt, contract) cycle >>= fun ctxt ->
  Storage.Contract.Frozen_fees.remove (ctxt, contract) cycle >>= fun ctxt ->
  Storage.Contract.Frozen_rewards.remove (ctxt, contract) cycle >>= fun ctxt ->
  return (ctxt, { deposit ; fees ; rewards })


let has_frozen_balance ctxt delegate cycle =
  let contract = Contract_repr.implicit_contract delegate in
  get_frozen_deposit ctxt contract cycle >>=? fun deposit ->
  if Tez_repr.(deposit <> zero) then return true
  else
    get_frozen_fees ctxt contract cycle >>=? fun fees ->
    if Tez_repr.(fees <> zero) then return true
    else
      get_frozen_rewards ctxt contract cycle >>=? fun rewards ->
      return Tez_repr.(rewards <> zero)

let frozen_balance_by_cycle_encoding =
  let open Data_encoding in
  conv
    (Cycle_repr.Map.bindings)
    (List.fold_left
       (fun m (c, b) -> Cycle_repr.Map.add c b m)
       Cycle_repr.Map.empty)
    (list (merge_objs
             (obj1 (req "cycle" Cycle_repr.encoding))
             frozen_balance_encoding))

let empty_frozen_balance =
  { deposit = Tez_repr.zero ;
    fees = Tez_repr.zero ;
    rewards = Tez_repr.zero }

let frozen_balance_by_cycle ctxt delegate =
  let contract = Contract_repr.implicit_contract delegate in
  let map = Cycle_repr.Map.empty in
  Storage.Contract.Frozen_deposits.fold
    (ctxt, contract) ~init:map
    ~f:(fun cycle amount map ->
        Lwt.return
          (Cycle_repr.Map.add cycle
             { empty_frozen_balance with deposit = amount } map)) >>= fun map ->
  Storage.Contract.Frozen_fees.fold
    (ctxt, contract) ~init:map
    ~f:(fun cycle amount map ->
        let balance =
          match Cycle_repr.Map.find_opt cycle map with
          | None -> empty_frozen_balance
          | Some balance -> balance in
        Lwt.return
          (Cycle_repr.Map.add cycle
             { balance with fees = amount } map)) >>= fun map ->
  Storage.Contract.Frozen_rewards.fold
    (ctxt, contract) ~init:map
    ~f:(fun cycle amount map ->
        let balance =
          match Cycle_repr.Map.find_opt cycle map with
          | None -> empty_frozen_balance
          | Some balance -> balance in
        Lwt.return
          (Cycle_repr.Map.add cycle
             { balance with rewards = amount } map)) >>= fun map ->
  Lwt.return map

let frozen_balance ctxt delegate =
  let contract = Contract_repr.implicit_contract delegate in
  let balance = Ok Tez_repr.zero in
  Storage.Contract.Frozen_deposits.fold
    (ctxt, contract) ~init:balance
    ~f:(fun _cycle amount acc ->
        Lwt.return acc >>=? fun acc ->
        Lwt.return (Tez_repr.(acc +? amount))) >>= fun balance ->
  Storage.Contract.Frozen_fees.fold
    (ctxt, contract) ~init:balance
    ~f:(fun _cycle amount acc ->
        Lwt.return acc >>=? fun acc ->
        Lwt.return (Tez_repr.(acc +? amount))) >>= fun balance ->
  Storage.Contract.Frozen_rewards.fold
    (ctxt, contract) ~init:balance
    ~f:(fun _cycle amount acc ->
        Lwt.return acc >>=? fun acc ->
        Lwt.return (Tez_repr.(acc +? amount))) >>= fun balance ->
  Lwt.return balance

let full_balance ctxt delegate =
  let contract = Contract_repr.implicit_contract delegate in
  frozen_balance ctxt delegate >>=? fun frozen_balance ->
  Storage.Contract.Balance.get ctxt contract >>=? fun balance ->
  Lwt.return Tez_repr.(frozen_balance +? balance)

let deactivated ctxt delegate =
  let contract = Contract_repr.implicit_contract delegate in
  Storage.Contract.Inactive_delegate.mem ctxt contract

let grace_period ctxt delegate =
  let contract = Contract_repr.implicit_contract delegate in
  Storage.Contract.Delegate_desactivation.get ctxt contract

let staking_balance ctxt delegate =
  let token_per_rolls = Constants_storage.tokens_per_roll ctxt in
  Roll_storage.get_rolls ctxt delegate >>=? fun rolls ->
  Roll_storage.get_change ctxt delegate >>=? fun change ->
  let rolls = Int64.of_int (List.length rolls) in
  Lwt.return Tez_repr.(token_per_rolls *? rolls) >>=? fun balance ->
  Lwt.return Tez_repr.(balance +? change)

let delegated_balance ctxt delegate =
  let contract = Contract_repr.implicit_contract delegate in
  staking_balance ctxt delegate >>=? fun staking_balance ->
  Storage.Contract.Balance.get ctxt contract >>= fun self_staking_balance ->
  Storage.Contract.Frozen_deposits.fold
    (ctxt, contract) ~init:self_staking_balance
    ~f:(fun _cycle amount acc ->
        Lwt.return acc >>=? fun acc ->
        Lwt.return (Tez_repr.(acc +? amount))) >>= fun self_staking_balance ->
  Storage.Contract.Frozen_fees.fold
    (ctxt, contract) ~init:self_staking_balance
    ~f:(fun _cycle amount acc ->
        Lwt.return acc >>=? fun acc ->
        Lwt.return (Tez_repr.(acc +? amount))) >>=? fun self_staking_balance ->
  Lwt.return Tez_repr.(staking_balance -? self_staking_balance)
