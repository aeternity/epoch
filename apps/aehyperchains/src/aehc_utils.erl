-module(aehc_utils).

-export([ hc_enabled/0
        , submit_commitment/2
        , delegates/1
        ]).

-export([stake/0]).

-export([pub/0, priv/0]).

-include("../../aecore/include/blocks.hrl").
-include("aehc_utils.hrl").

-spec hc_enabled() -> boolean().
hc_enabled() ->
    Config = aec_consensus:get_consensus(),
    HC = [1 || {_, {aehc_consensus_hyperchains, _}} <- Config],
    HC /= [].

-spec submit_commitment(node(), binary()) -> aehc_parent_block:parent_block().
submit_commitment(KeyNode, Delegate) ->
    aec_events:subscribe(parent_top_changed),

    C = aehc_commitment:new(aehc_commitment_header:new(Delegate, aec_block_insertion:node_hash(KeyNode)), no_pogf),
    ok = aehc_parent_mng:commit(C),

    receive
        {gproc_ps_event, parent_top_changed, _Info} ->
            ok
    end,
    {_, ParentBlock} = aehc_parent_mng:pop(),

    ParentBlock.

-spec delegates(block_header_hash()) -> [commiter_pubkey()].
delegates(ParentHash) ->
    Commitments = aehc_parent_mng:commitments(ParentHash),
    Accounts = [aehc_commitment_header:hc_delegate(aehc_commitment:header(X)) || X <- Commitments],

    State = aehc_parent_trees:delegates(aehc_parent_db:get_parent_block_state(ParentHash)),
    [begin {value, Delegate} = aehc_delegates_trees:lookup(A, State), Delegate end|| A <- Accounts].

stake() ->
    {ok, ContractAddress} = aehc_consensus_hyperchains:get_staking_contract_address(),
    Aci = aehc_consensus_hyperchains:get_staking_contract_aci(),
%%    AE = math:pow(10, 18),
    Fee = 1 bsl 60,
    Gas = 1 bsl 30,
    GasPrice = 1 bsl 30,
    MkCallF =
        fun(#{ pubkey := Pub, privkey := Priv }, Nonce, Amount, Call) ->
            Tx = make_contract_call_tx(Pub, ContractAddress, Call, Nonce, Amount, Fee, Gas, GasPrice),
            sign_tx(Tx, Priv, false, undefined)
        end,
    {ok, CallDepositStake} = aeaci_aci:encode_call_data(Aci, "deposit_stake()"),
    R = MkCallF(patron(), 1, 1 * 1000000000000000000, CallDepositStake),
    aec_tx_pool:push(R).

make_contract_call_tx(Pubkey, ContractPubkey, CallData, Nonce, Amount, Fee,
    Gas, GasPrice) ->
    {ok, Tx} = aect_call_tx:new(#{ caller_id   => aeser_id:create(account, Pubkey)
        , nonce       => Nonce
        , contract_id => aeser_id:create(contract, ContractPubkey)
        , abi_version => staking_contract_abi()
        , fee         => Fee
        , amount      => Amount
        , gas         => Gas
        , gas_price   => GasPrice
        , call_data   => CallData
    }),
    Tx.

staking_contract_abi() -> 3.

sign_tx(Tx, PrivKey, SignHash, AdditionalPrefix) when is_binary(PrivKey) ->
    sign_tx(Tx, [PrivKey], SignHash, AdditionalPrefix);
sign_tx(Tx, PrivKeys, SignHash, AdditionalPrefix) when is_list(PrivKeys) ->
    Bin0 = aetx:serialize_to_binary(Tx),
    Bin1 =
        case SignHash of
            true  -> aec_hash:hash(signed_tx, Bin0);
            false -> Bin0
        end,
    Bin =
        case AdditionalPrefix of
            undefined -> Bin1;
            _ ->
                <<"-", AdditionalPrefix/binary, Bin1/binary>>
        end,
    BinForNetwork = aec_governance:add_network_id(Bin),
    case lists:filter(fun(PrivKey) -> not (byte_size(PrivKey) =:= 64) end, PrivKeys) of
        [_|_]=BrokenKeys -> erlang:error({invalid_priv_key, BrokenKeys});
        [] -> pass
    end,
    Signatures = [ enacl:sign_detached(BinForNetwork, PrivKey) || PrivKey <- PrivKeys ],
    aetx_sign:new(Tx, Signatures).

patron() ->
    #{
        pubkey  => pub(),
        privkey => priv()
    }.

pub() ->
    <<206,167,173,228,112,201,249,157,157,78,64,8,128,168,111,29, 73,187,68,75,98,241,26,158,187,100,187,207,235,115,254,243>>.

priv() ->
    <<230,169,29,99,60,119,207,87,113,50,157,51,84,179,188,239,27, 197,224,50,196,61,112,182,211,90,249,35,206,30,183,77,206, 167,173,228,112,201,249,157,157,78,64,8,128,168,111,29,73, 187,68,75,98,241,26,158,187,100,187,207,235,115,254,243>>.
