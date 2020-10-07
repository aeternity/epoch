%%% -*- erlang-indent-level: 4 -*-
%%%-------------------------------------------------------------------
-module(aehc_chain_sim_connector).

-behaviour(aehc_connector).
-behaviour(gen_server).

%% API.
-export([start_link/0]).

%% gen_server.
-export([init/1]).
-export([handle_call/3]).
-export([handle_cast/2]).
-export([handle_info/2]).
-export([terminate/2]).

-export([send_tx/3, get_block_by_hash/1, get_top_block/0]).

%% API.

-spec start_link() ->
    {ok, pid()} | ingnore | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%%===================================================================
%%%  aehc_connector behaviour
%%%===================================================================

-spec send_tx(binary(), binary(), binary()) -> binary().
send_tx(Delegate, Commitment, PoGF) ->
    gen_server:call(?MODULE, {send_tx, Delegate, Commitment, PoGF}).

-spec get_top_block() -> aehc_parent_block:parent_block().
get_top_block() ->
    gen_server:call(?MODULE, {get_top_block}).

-spec get_block_by_hash(binary()) -> aehc_parent_block:parent_block().
get_block_by_hash(Hash) ->
    gen_server:call(?MODULE, {get_block_by_hash, Hash}).

%%%===================================================================
%%%  gen_server behaviour
%%%===================================================================

-record(state, { pid::pid(), height = 0::non_neg_integer() }).

init([]) ->
    process_flag(trap_exit, true),
    true = aec_events:subscribe(top_changed),
    {ok, Pid} = aec_chain_sim:start(#{ simulator => parent_chain }),
    lager:info("Parent chain's connector ~p is attached: ~p", [?MODULE, Pid]),
    {ok, #state{ pid = Pid }}.

handle_call({send_tx, Delegate, _Commitment, _PoGF}, _From, State) ->
    %% The current validator credentials;
    %% Requested transaction by hash from a simulator's block should satisfy the origin of validator;
    {ok, PrivKey} = aec_keys:sign_privkey(),
    %% The main intention of this call is to emulate post action with signed payload from delegate;
    %% Fee, nonce, ttl and amount fields have decorated nature;
    Header = aehc_commitment_header:new(<<"D1">>, <<"BLOCK 1">>),
    Payload = aehc_commitment_header:hash(Header),
    {ok, Tx} = aec_spend_tx:new(#{ sender_id => Delegate, recipient_id => Delegate, amount => 1,
                                        fee => 5, nonce => 1, payload => Payload, ttl => 0 }),
    BinaryTx = aec_governance:add_network_id(aetx:serialize_to_binary(Tx)),
    SignedTx = aetx_sign:new(Tx, [enacl:sign_detached(BinaryTx, PrivKey)]),
    TxHash = aetx_sign:hash(SignedTx),
    %% The next format is prepared accordingly to simualtor internal representation;
    Res = aec_chain_sim:push(#{ tx_hash => TxHash, signed_tx  => SignedTx }),
    {reply, Res, State};

handle_call({get_top_block}, _From, State) ->
    Hash = aec_chain_sim:top_block_hash(),
    {ok, Info} = aec_chain_sim:block_by_hash(Hash),
    Block = format_block(Info),
    {reply, {ok, Block}, State};

handle_call({get_block_by_hash, Hash}, _From, State) ->
    {ok, Info} = aec_chain_sim:block_by_hash(Hash),
    Block = format_block(Info),
    {reply, {ok, Block}, State};

handle_call(Request, _From, State) ->
    lager:info("Unexpected call: ~p", [Request]),
    {reply, ignored, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info({gproc_ps_event, {parent_chain, top_changed}, #{info := Info}}, State) ->
    Pid = maps:get(pid, Info, undefined),
    (State#state.pid == Pid) andalso
        begin
            Block = format_block(Info),
            aehc_connector:publish_block(?MODULE, Block)
        end,
    {noreply, State};

handle_info(Info, State) ->
    lager:info("Unexpected message: ~p", [Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

-spec payload(aetx_sign:signed_tx()) -> binary().
payload(SignedTx) ->
    Tx = aetx_sign:tx(SignedTx), SpendTx = aetx:tx(Tx),
    Payload = aec_spend_tx:payload(SpendTx), true = is_binary(Payload),
    Payload.

-spec sender_id(aetx_sign:signed_tx()) -> binary().
sender_id(SignedTx) ->
    Tx = aetx_sign:tx(SignedTx), SpendTx = aetx:tx(Tx),
    SenderId = aec_spend_tx:sender_id(SpendTx), true = is_binary(SenderId),
    SenderId.

format_block(SimBlock) ->
    _Txs = [aehc_connector:tx(sender_id(Tx), payload(Tx)) || Tx <- maps:get(txs, SimBlock)],
    Hash = maps:get(block_hash, SimBlock),
    PrevHash = maps:get(prev_hash, SimBlock),
    %% TODO To update simulator with ability to pass height;
    aehc_connector:parent_block(0, Hash, PrevHash, []).
