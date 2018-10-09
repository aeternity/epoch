%%%=============================================================================
%%% @copyright 2018, Aeternity Anstalt
%%% @doc
%%%    Module defining the State Channel withdraw transaction
%%% @end
%%%=============================================================================
-module(aesc_withdraw_tx).

-behavior(aetx).
-behaviour(aesc_signable_transaction).

%% Behavior API
-export([new/1,
         type/0,
         fee/1,
         ttl/1,
         nonce/1,
         origin/1,
         amount/1,
         check/3,
         process/3,
         signers/2,
         version/0,
         serialization_template/1,
         serialize/1,
         deserialize/2,
         for_client/1
        ]).

% aesc_signable_transaction callbacks
-export([channel_id/1,
         channel_pubkey/1,
         state_hash/1,
         updates/1,
         round/1]).

%%%===================================================================
%%% Types
%%%===================================================================

-define(CHANNEL_WITHDRAW_TX_VSN, 1).
-define(CHANNEL_WITHDRAW_TX_TYPE, channel_withdraw_tx).

-type vsn() :: non_neg_integer().

%% HERE
-record(channel_withdraw_tx, {
          channel_id  :: aec_id:id(),
          to_id       :: aec_id:id(),
          amount      :: non_neg_integer(),
          ttl         :: aetx:tx_ttl(),
          fee         :: non_neg_integer(),
          state_hash  :: binary(),
          round       :: non_neg_integer(),
          nonce       :: non_neg_integer()
         }).

-opaque tx() :: #channel_withdraw_tx{}.

-export_type([tx/0]).

-compile({no_auto_import, [round/1]}).

%%%===================================================================
%%% Behaviour API
%%%===================================================================

-spec new(map()) -> {ok, aetx:tx()}.
new(#{channel_id := ChannelId,
      to_id      := ToId,
      amount     := Amount,
      fee        := Fee,
      state_hash := StateHash,
      round      := Round,
      nonce      := Nonce} = Args) ->
    true = aesc_utils:check_state_hash_size(StateHash),
    channel = aec_id:specialize_type(ChannelId),
    account = aec_id:specialize_type(ToId),
    Tx = #channel_withdraw_tx{
            channel_id = ChannelId,
            to_id      = ToId,
            amount     = Amount,
            ttl        = maps:get(ttl, Args, 0),
            fee        = Fee,
            state_hash = StateHash,
            round      = Round,
            nonce      = Nonce},
    {ok, aetx:new(?MODULE, Tx)}.

type() ->
    ?CHANNEL_WITHDRAW_TX_TYPE.

-spec fee(tx()) -> non_neg_integer().
fee(#channel_withdraw_tx{fee = Fee}) ->
    Fee.

-spec ttl(tx()) -> aetx:tx_ttl().
ttl(#channel_withdraw_tx{ttl = TTL}) ->
    TTL.

-spec nonce(tx()) -> non_neg_integer().
nonce(#channel_withdraw_tx{nonce = Nonce}) ->
    Nonce.

-spec origin(tx()) -> aec_keys:pubkey().
origin(#channel_withdraw_tx{} = Tx) ->
    to_pubkey(Tx).

to_pubkey(#channel_withdraw_tx{to_id = ToId}) ->
    aec_id:specialize(ToId, account).

-spec channel_pubkey(tx()) -> aesc_channels:pubkey().
channel_pubkey(#channel_withdraw_tx{channel_id = ChannelId}) ->
    aec_id:specialize(ChannelId, channel).

-spec channel_id(tx()) -> aesc_channels:id().
channel_id(#channel_withdraw_tx{channel_id = ChannelId}) ->
    ChannelId.

-spec amount(tx()) -> non_neg_integer().
amount(#channel_withdraw_tx{amount = Amt}) ->
    Amt.

-spec check(tx(), aec_trees:trees(), aetx_env:env()) -> {ok, aec_trees:trees()} | {error, term()}.
check(#channel_withdraw_tx{amount       = Amount,
                           fee          = Fee,
                           state_hash   = _StateHash,
                           round        = Round,
                           nonce        = Nonce} = Tx,
     Trees,_Env) ->
    ChannelPubKey = channel_pubkey(Tx),
    ToPubKey      = to_pubkey(Tx),
    Checks =
        [fun() -> aetx_utils:check_account(ToPubKey, Trees, Nonce, Fee) end,
         fun() -> check_channel(ChannelPubKey, Amount, ToPubKey, Round, Trees) end],
    case aeu_validation:run(Checks) of
        ok ->
            {ok, Trees};
        {error, _Reason} = Error ->
            Error
    end.

-spec process(tx(), aec_trees:trees(), aetx_env:env()) -> {ok, aec_trees:trees()}.
process(#channel_withdraw_tx{amount       = Amount,
                             fee          = Fee,
                             state_hash   = StateHash,
                             round        = Round,
                             nonce        = Nonce} = Tx,
        Trees,_Env) ->
    ChannelPubKey = channel_pubkey(Tx),
    ToPubKey      = to_pubkey(Tx),
    AccountsTree0 = aec_trees:accounts(Trees),
    ChannelsTree0 = aec_trees:channels(Trees),

    ToAccount0       = aec_accounts_trees:get(ToPubKey, AccountsTree0),
    {ok, ToAccount1} = aec_accounts:spend(ToAccount0, Fee, Nonce),
    {ok, ToAccount2} = aec_accounts:earn(ToAccount1, Amount),

    AccountsTree1 = aec_accounts_trees:enter(ToAccount2, AccountsTree0),

    Channel0      = aesc_state_tree:get(ChannelPubKey, ChannelsTree0),
    Channel1      = aesc_channels:withdraw(Channel0, Amount, Round, StateHash),
    ChannelsTree1 = aesc_state_tree:enter(Channel1, ChannelsTree0),

    Trees1 = aec_trees:set_accounts(Trees, AccountsTree1),
    Trees2 = aec_trees:set_channels(Trees1, ChannelsTree1),
    {ok, Trees2}.

-spec signers(tx(), aec_trees:trees()) -> {ok, list(aec_keys:pubkey())}
                                        | {error, channel_not_found}.
signers(#channel_withdraw_tx{} = Tx, Trees) ->
    ChannelPubKey = channel_pubkey(Tx),
    case aec_chain:get_channel(ChannelPubKey, Trees) of
        {ok, Channel} ->
            {ok, [aesc_channels:initiator_pubkey(Channel),
                  aesc_channels:responder_pubkey(Channel)]};
        {error, not_found} -> {error, channel_not_found}
    end.

-spec serialize(tx()) -> {vsn(), list()}.
serialize(#channel_withdraw_tx{channel_id = ChannelId,
                               to_id      = ToId,
                               amount     = Amount,
                               ttl        = TTL,
                               fee        = Fee,
                               state_hash = StateHash,
                               round      = Round,
                               nonce      = Nonce}) ->
    {version(),
     [ {channel_id , ChannelId}
     , {to_id      , ToId}
     , {amount     , Amount}
     , {ttl        , TTL}
     , {fee        , Fee}
     , {state_hash , StateHash}
     , {round      , Round}
     , {nonce      , Nonce}
     ]}.

-spec deserialize(vsn(), list()) -> tx().
deserialize(?CHANNEL_WITHDRAW_TX_VSN,
            [ {channel_id , ChannelId}
            , {to_id      , ToId}
            , {amount     , Amount}
            , {ttl        , TTL}
            , {fee        , Fee}
            , {state_hash , StateHash}
            , {round      , Round}
            , {nonce      , Nonce}]) ->
    channel = aec_id:specialize_type(ChannelId),
    account = aec_id:specialize_type(ToId),
    true = aesc_utils:check_state_hash_size(StateHash),
    #channel_withdraw_tx{channel_id = ChannelId,
                         to_id      = ToId,
                         amount     = Amount,
                         ttl        = TTL,
                         fee        = Fee,
                         state_hash = StateHash,
                         round      = Round,
                         nonce      = Nonce}.

-spec for_client(tx()) -> map().
for_client(#channel_withdraw_tx{channel_id   = ChannelId,
                                to_id        = ToId,
                                amount       = Amount,
                                ttl          = TTL,
                                fee          = Fee,
                                state_hash   = StateHash,
                                round        = Round,
                                nonce        = Nonce}) ->
    #{<<"channel_id">>  => aec_base58c:encode(id_hash, ChannelId),
      <<"to_id">>       => aec_base58c:encode(id_hash, ToId),
      <<"amount">>      => Amount,
      <<"ttl">>         => TTL,
      <<"fee">>         => Fee,
      <<"state_hash">>  => aec_base58c:encode(state, StateHash),
      <<"round">>       => Round,
      <<"nonce">>       => Nonce}.

serialization_template(?CHANNEL_WITHDRAW_TX_VSN) ->
    [ {channel_id , id}
    , {to_id      , id}
    , {amount     , int}
    , {ttl        , int}
    , {fee        , int}
    , {state_hash , binary}
    , {round      , int}
    , {nonce      , int}
    ].

state_hash(#channel_withdraw_tx{state_hash = StateHash}) -> StateHash.

updates(#channel_withdraw_tx{to_id = ToId, amount = Amount}) ->
    [aesc_offchain_update:op_withdraw(ToId, Amount)].

round(#channel_withdraw_tx{round = Round}) ->
    Round.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec check_channel(aesc_channels:pubkey(), aesc_channels:amount(),
                    aec_keys:pubkey(), non_neg_integer(), aec_trees:trees()) ->
                           ok | {error, atom()}.
check_channel(ChannelPubKey, Amount, ToPubKey, Round, Trees) ->
    case aesc_state_tree:lookup(ChannelPubKey, aec_trees:channels(Trees)) of
        {value, Channel} ->
            Checks =
                [fun() -> aesc_utils:check_is_active(Channel) end,
                 fun() -> aesc_utils:check_is_peer(ToPubKey, aesc_channels:peers(Channel)) end,
                 fun() -> check_amount(Channel, Amount) end,
                 fun() -> aesc_utils:check_round_greater_than_last(Channel,
                                                                   Round,
                                                                   withdrawal)
                 end
                ],
            aeu_validation:run(Checks);
        none ->
            {error, channel_does_not_exist}
    end.

-spec check_amount(aesc_channels:channel(), aesc_channels:amount()) ->
                          ok | {error, not_enough_channel_funds}.
check_amount(Channel, Amount) ->
    MaxWithdrawableAmt = aesc_channels:channel_amount(Channel) -
                         2 * aesc_channels:channel_reserve(Channel),
    case MaxWithdrawableAmt >= Amount of
        true ->
            ok;
        false ->
            {error, not_enough_channel_funds}
    end.

-spec version() -> non_neg_integer().
version() ->
    ?CHANNEL_WITHDRAW_TX_VSN.
