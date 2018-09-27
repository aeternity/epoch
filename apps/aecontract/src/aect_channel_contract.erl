-module(aect_channel_contract).
-include_lib("apps/aecore/include/blocks.hrl").
-include("aecontract.hrl").

-export([new/6,
         run_new/7,
         run/12,
         get_call/4,
         insert_failed_call/6
        ]).

new(Owner, Round, VmVersion, Code, Deposit, Trees0) ->
    %% Create the contract and insert it into the contract state tree
    %%   The public key for the contract is generated from the owners pubkey
    %%   and the nonce, so that no one has the private key.
    Contract        = aect_contracts:new(Owner, Round, VmVersion, Code, Deposit),
    ContractId      = aect_contracts:id(Contract),
    ContractsTree0  = aec_trees:contracts(Trees0),
    ContractsTree1  = aect_state_tree:insert_contract(Contract, ContractsTree0),
    Trees1          = aec_trees:set_contracts(Trees0, ContractsTree1),
    {ContractId, Contract, Trees1}.

-spec run_new(aect_contracts:pubkey(), aect_call:call(), binary(),
              non_neg_integer(), aec_trees:trees(), aec_trees:trees(),
              aetx_env:env()) -> aec_trees:trees().
run_new(ContractPubKey, Call, CallData, Round, Trees0, OnChainTrees,
        OnChainEnv) ->
    ContractsTree  = aec_trees:contracts(Trees0),
    Contract = aect_state_tree:get_contract(ContractPubKey, ContractsTree),
    OwnerPubKey = aect_contracts:owner_pubkey(Contract),
    Code = aect_contracts:code(Contract),
    CallStack = [], %% TODO: should we have a call stack for create_tx also
                    %% when creating a contract in a contract.
    VmVersion = aect_contracts:vm_version(Contract),
    CallDef = make_call_def(OwnerPubKey, ContractPubKey,
                            _Gas = 1000000, _GasPrice = 1,
                            _Amount = 0, %TODO: make this configurable
                            CallData, CallStack, Code, Call, OnChainTrees, OnChainEnv, Trees0,
                            Round),
    {CallRes, Trees} = aect_dispatch:run(VmVersion, CallDef),
    case aect_call:return_type(CallRes) of
        ok ->
            Trees1 = aect_utils:insert_call_in_trees(CallRes, Trees),
            Contract1 =
                case VmVersion of
                    ?AEVM_01_Sophia_01 ->
                        %% Save the initial state (returned by `init`) in the store.
                        InitState  = aect_call:return_value(CallRes),
                        %% TODO: move to/from_sophia_state to make nicer dependencies?
                        aect_contracts:set_state(
                          aevm_eeevm_store:from_sophia_state(InitState), Contract);
                    ?AEVM_01_Solidity_01 ->
                        %% Solidity inital call returns the code to store in the contract.
                        NewCode = aect_call:return_value(CallRes),
                        aect_contracts:set_code(NewCode, Contract)
                end,
            ContractsTree0 = aec_trees:contracts(Trees1),
            ContractsTree1 = aect_state_tree:enter_contract(Contract1, ContractsTree0),
            aec_trees:set_contracts(Trees1, ContractsTree1);
        E ->
            lager:debug("Init call error ~w ~w~n",[E, CallRes]),
            Trees0
    end.

-spec run(aect_contracts:pubkey(), aect_contracts:vm_version(), aect_call:call(),
          binary(), [non_neg_integer()], non_neg_integer(), aec_trees:trees(),
          non_neg_integer(), non_neg_integer(), non_neg_integer(),
          aec_trees:trees(), aetx_env:env()) -> aec_trees:trees().
run(ContractPubKey, VmVersion, Call, CallData, CallStack, Round, Trees0,
    Amount, GasPrice, Gas, OnChainTrees, OnChainEnv) ->
    ContractsTree  = aec_trees:contracts(Trees0),
    Contract = aect_state_tree:get_contract(ContractPubKey, ContractsTree),
    OwnerPubKey = aect_contracts:owner_pubkey(Contract),
    Code = aect_contracts:code(Contract),
    case aect_contracts:vm_version(Contract) =:= VmVersion of
        true  -> ok;
        false ->  erlang:error(wrong_vm_version)
    end,
    CallDef = make_call_def(OwnerPubKey, ContractPubKey, Gas, GasPrice, Amount,
              CallData, CallStack, Code, Call, OnChainTrees, OnChainEnv, Trees0,
              Round),
    {CallRes, Trees} = aect_dispatch:run(VmVersion, CallDef),
    aect_utils:insert_call_in_trees(CallRes, Trees).

make_call_def(OwnerPubKey, ContractPubKey, GasLimit, GasPrice, Amount,
              CallData, CallStack, Code, Call, OnChainTrees, OnChainEnv, OffChainTrees, Round) ->
    Time = aetx_env:time_in_msecs(OnChainEnv),
    #{caller          => OwnerPubKey
    , contract        => ContractPubKey
    , gas             => GasLimit
    , gas_price       => GasPrice
    , call_data       => CallData
    , amount          => Amount
    , call_stack      => CallStack
    , code            => Code
    , call            => Call
    , trees           => OffChainTrees
    , tx_env          => tx_env(Round, Time)
    , off_chain       => true
    , on_chain_trees  => OnChainTrees
    , on_chain_env    => OnChainEnv
    }.

tx_env(Round, Time) ->
    %% We do not want the execution off chain and
    %% on chain to be different so therea are some default values.

    %% Beneficiary is always 0
    Beneficiary = <<0:?BENEFICIARY_PUB_BYTES/unit:8>>,
    %% Block hash is always 0
    PrevKeyHash = <<0:?BLOCK_HEADER_HASH_BYTES/unit:8>>,
    %% TODO: Default value for offchain
    Difficulty = 0,
    %% TODO: Proper consensus version should be set
    ConsensusVersion = ?PROTOCOL_VERSION,
    aetx_env:contract_env(Round, ConsensusVersion, Time,
                          Beneficiary, Difficulty, PrevKeyHash).

get_call(ContractPubkey, CallerPubkey, Round, CallsTree) ->
    CallId = aect_call:id(CallerPubkey, Round, ContractPubkey),
    case aect_call_state_tree:lookup_call(ContractPubkey, CallId, CallsTree) of
        none -> {error, call_not_found};
        {value, Call} -> {ok, Call}
    end.

-spec insert_failed_call(aect_contracts:pubkey(), aec_keys:pubkey(),
                         non_neg_integer(), non_neg_integer(),
                         non_neg_integer(), aect_call_state_tree:tree()) ->
                         aect_call_state_tree:tree().
insert_failed_call(ContractPubkey, CallerPubkey, Round, GasPrice, GasLimit, CallsTree) ->
    Caller = aec_id:create(account, CallerPubkey),
    Contract = aec_id:create(contract, ContractPubkey),
    Call0 = aect_call:new(Caller, Round, Contract, Round, GasPrice),
    Call1 = aect_call:set_gas_used(GasLimit, Call0), % all gas is consumed
    Call2 = aect_call:set_return_type(error, Call1),
    Call = aect_call:set_return_value(<<"invalid_call">>, Call2),
    aect_call_state_tree:insert_call(Call, CallsTree).
