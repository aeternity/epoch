%%%=============================================================================
%%% @copyright 2017, Aeternity Anstalt
%%% @doc
%%%    Module defining the Oracle register transaction
%%% @end
%%%=============================================================================
-module(aeo_extend_tx).

-include("oracle_txs.hrl").

-behavior(aetx).

%% Behavior API
-export([new/1,
         type/0,
         fee/1,
         gas/1,
         ttl/1,
         nonce/1,
         origin/1,
         check/3,
         process/3,
         signers/2,
         version/0,
         serialize/1,
         serialization_template/1,
         deserialize/2,
         for_client/1
        ]).

%% Additional getters
-export([oracle_id/1,
         oracle_pubkey/1,
         oracle_ttl/1]).

-define(ORACLE_EXTEND_TX_VSN, 1).
-define(ORACLE_EXTEND_TX_TYPE, oracle_extend_tx).

-record(oracle_extend_tx, {
          oracle_id  :: aec_id:id(),
          nonce      :: integer(),
          oracle_ttl :: aeo_oracles:relative_ttl(),
          fee        :: integer(),
          ttl        :: aetx:tx_ttl()
          }).

-opaque tx() :: #oracle_extend_tx{}.

-export_type([tx/0]).

-spec oracle_id(tx()) -> aec_id:id().
oracle_id(#oracle_extend_tx{oracle_id = OracleId}) ->
    OracleId.

-spec oracle_pubkey(tx()) -> aec_keys:pubkey().
oracle_pubkey(#oracle_extend_tx{oracle_id = OracleId}) ->
    aec_id:specialize(OracleId, oracle).

-spec oracle_ttl(tx()) -> aeo_oracles:relative_ttl().
oracle_ttl(#oracle_extend_tx{oracle_ttl = OTTL}) ->
    OTTL.

-spec fee(tx()) -> integer().
fee(#oracle_extend_tx{fee = Fee}) ->
    Fee.

-spec gas(tx()) -> non_neg_integer().
gas(#oracle_extend_tx{}) ->
    0.

-spec ttl(tx()) -> aetx:tx_ttl().
ttl(#oracle_extend_tx{ttl = TTL}) ->
    TTL.

-spec new(map()) -> {ok, aetx:tx()}.
new(#{oracle_id  := OracleId,
      nonce      := Nonce,
      oracle_ttl := OracleTTL,
      fee        := Fee} = Args) ->
    oracle = aec_id:specialize_type(OracleId),
    Tx = #oracle_extend_tx{oracle_id  = OracleId,
                           nonce      = Nonce,
                           oracle_ttl = OracleTTL,
                           fee        = Fee,
                           ttl        = maps:get(ttl, Args, 0)},
    {ok, aetx:new(?MODULE, Tx)}.

-spec type() -> atom().
type() ->
    ?ORACLE_EXTEND_TX_TYPE.

-spec nonce(tx()) -> non_neg_integer().
nonce(#oracle_extend_tx{nonce = Nonce}) ->
    Nonce.

-spec origin(tx()) -> aec_keys:pubkey().
origin(#oracle_extend_tx{} = Tx) ->
    oracle_pubkey(Tx).

%% Account should exist, and have enough funds for the fee
%% Oracle should exist.
-spec check(tx(), aec_trees:trees(), aetx_env:env()) -> {ok, aec_trees:trees()} | {error, term()}.
check(#oracle_extend_tx{nonce = Nonce, oracle_ttl = OTTL, fee = Fee} = Tx,
      Trees,_Env) ->
    OraclePK = oracle_pubkey(Tx),
    Checks =
        [fun() -> check_oracle_extension_ttl(OTTL) end],

    case aeu_validation:run(Checks) of
        ok              -> {ok, Trees};
        {error, Reason} -> {error, Reason}
    end.

-spec signers(tx(), aec_trees:trees()) -> {ok, [aec_keys:pubkey()]}.
signers(#oracle_extend_tx{} = Tx, _) ->
    {ok, [oracle_pubkey(Tx)]}.

-spec process(tx(), aec_trees:trees(), aetx_env:env()) -> {ok, aec_trees:trees()}.
process(#oracle_extend_tx{} = Tx, Trees, Env) ->
    Pubkey = oracle_pubkey(Tx),
    {delta, DeltaTTL} = oracle_ttl(Tx),
    Instructions = [ {inc_account_nonce, Pubkey, nonce(Tx)}
                   , {spend_fee, Pubkey, fee(Tx)}
                   , {oracle_extend, Pubkey, DeltaTTL}
                   ],
    aec_tx_processor:eval(Instructions, Trees, aetx_env:height(Env)).

serialize(#oracle_extend_tx{oracle_id  = OracleId,
                            nonce      = Nonce,
                            oracle_ttl = {?ttl_delta_atom, TTLValue},
                            fee        = Fee,
                            ttl        = TTL}) ->
    {version(),
    [ {oracle_id, OracleId}
    , {nonce, Nonce}
    , {oracle_ttl_type, ?ttl_delta_int}
    , {oracle_ttl_value, TTLValue}
    , {fee, Fee}
    , {ttl, TTL}
    ]}.

deserialize(?ORACLE_EXTEND_TX_VSN,
           [ {oracle_id, OracleId}
           , {nonce, Nonce}
           , {oracle_ttl_type, ?ttl_delta_int}
           , {oracle_ttl_value, TTLValue}
           , {fee, Fee}
           , {ttl, TTL}]) ->
    oracle = aec_id:specialize_type(OracleId),
    #oracle_extend_tx{oracle_id  = OracleId,
                      nonce      = Nonce,
                      oracle_ttl = {?ttl_delta_atom, TTLValue},
                      fee        = Fee,
                      ttl        = TTL}.

serialization_template(?ORACLE_EXTEND_TX_VSN) ->
    [ {oracle_id, id}
    , {nonce, int}
    , {oracle_ttl_type, int}
    , {oracle_ttl_value, int}
    , {fee, int}
    , {ttl, int}
    ].

-spec version() -> non_neg_integer().
version() ->
    ?ORACLE_EXTEND_TX_VSN.

for_client(#oracle_extend_tx{oracle_id = OracleId,
                             nonce     = Nonce,
                             fee       = Fee,
                             ttl       = TTL} = Tx) ->
    {delta = TTLType, TTLValue} = oracle_ttl(Tx),
    #{<<"oracle_id">>   => aehttp_api_encoder:encode(id_hash, OracleId),
      <<"nonce">>       => Nonce,
      <<"oracle_ttl">>  => #{<<"type">>  => TTLType,
                             <<"value">> => TTLValue},
      <<"fee">>         => Fee,
      <<"ttl">>         => TTL}.

%% -- Local functions  -------------------------------------------------------

-dialyzer({no_match, check_oracle_extension_ttl/1}).
check_oracle_extension_ttl({delta, D}) when is_integer(D), D > 0 ->
    ok;
check_oracle_extension_ttl({delta, 0}) ->
    {error, zero_relative_oracle_extension_ttl};
check_oracle_extension_ttl({block, _}) ->
    {error, absolute_oracle_extension_ttl}.
