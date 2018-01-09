%%%-------------------------------------------------------------------
%%% @copyright (C) 2018, Aeternity Anstalt
%%% @doc
%%% ADT for name objects
%%% @end
%%%-------------------------------------------------------------------

-module(aens_names).

-include_lib("apps/aecore/include/common.hrl").

%% API
-export([hash_name/1,
         id/1,
         new/3,
         update/3,
         revoke/3,
         transfer/2,
         serialize/1,
         deserialize/1]).

%% Getters
-export([owner/1,
         status/1]).

%%%===================================================================
%%% Types
%%%===================================================================

-type name_status() :: claimed | revoked.

-record(name, {hash     :: binary(),
               owner    :: pubkey(),
               expires  :: height(),
               status   :: name_status(),
               ttl      :: integer(),
               pointers :: binary()}).

-opaque name() :: #name{}.

-type id() :: binary().
-type serialized() :: binary().

-export_type([id/0,
              name/0,
              serialized/0]).

-define(NAME_TYPE, <<"name">>).
-define(NAME_VSN, 1).

%%%===================================================================
%%% API
%%%===================================================================

-spec hash_name(binary()) -> binary().
hash_name(Name) ->
    %% TODO: Implement NameHash as described in https://github.com/aeternity/protocol/blob/aens/drafts/AENS.md#hashing
    Name.

-spec id(name()) -> binary().
id(N) ->
    hash(N).

-spec new(aens_claim_tx:claim_tx(), non_neg_integer(), height()) -> name().
new(ClaimTx, Expiration, BlockHeight) ->
    Expires = BlockHeight + Expiration,
    Hash = hash_name(aens_claim_tx:name(ClaimTx)),
    %% TODO: add assertions on fields, similarily to what is done in aeo_oracles:new/2
    #name{hash    = Hash,
          owner   = aens_claim_tx:account(ClaimTx),
          expires = Expires,
          status  = claimed}.

-spec update(aens_update_tx:update_tx(), name(), height()) -> name().
update(UpdateTx, Name, BlockHeight) ->
    Expires = BlockHeight + aens_update_tx:ttl(UpdateTx),
    Name#name{expires  = Expires,
              ttl      = aens_update_tx:name_ttl(UpdateTx),
              pointers = aens_update_tx:pointers(UpdateTx)}.

-spec revoke(name(), non_neg_integer(), height()) -> name().
revoke(Name, Expiration, BlockHeight) ->
    Expires = BlockHeight + Expiration,
    Name#name{status = revoked,
              expires = Expires}.

-spec transfer(aens_transfer_tx:transfer_tx(), name()) -> name().
transfer(TransferTx, Name) ->
    Name#name{owner = aens_transfer_tx:recipient_account(TransferTx)}.

-spec serialize(name()) -> binary().
serialize(#name{} = N) ->
    msgpack:pack([#{<<"type">>     => ?NAME_TYPE},
                  #{<<"vsn">>      => ?NAME_VSN},
                  #{<<"hash">>     => hash(N)},
                  #{<<"owner">>    => owner(N)},
                  #{<<"expires">>  => expires(N)},
                  #{<<"status">>   => status(N)},
                  #{<<"ttl">>      => ttl(N)},
                  #{<<"pointers">> => pointers(N)}]).

-spec deserialize(binary()) -> name().
deserialize(Bin) ->
    {ok, List} = msgpack:unpack(Bin),
    [#{<<"type">>     := ?NAME_TYPE},
     #{<<"vsn">>      := ?NAME_VSN},
     #{<<"hash">>     := Hash},
     #{<<"owner">>    := Owner},
     #{<<"expires">>  := Expires},
     #{<<"status">>   := Status},
     #{<<"ttl">>      := TTL},
     #{<<"pointers">> := Pointers}] = List,
    #name{hash     = Hash,
          owner    = Owner,
          expires  = Expires,
          status   = Status,
          ttl      = TTL,
          pointers = Pointers}.

%%%===================================================================
%%% Getters
%%%===================================================================

-spec owner(name()) -> pubkey().
owner(N) -> N#name.owner.

-spec status(name()) -> name_status().
status(N) -> N#name.status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

-spec expires(name()) -> height().
expires(N) -> N#name.expires.

-spec hash(name()) -> binary().
hash(N) -> N#name.hash.

-spec pointers(name()) -> binary().
pointers(N) -> N#name.pointers.

-spec ttl(name()) -> integer().
ttl(N) -> N#name.ttl.
