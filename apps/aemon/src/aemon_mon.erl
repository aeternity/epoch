%% @doc This module implements a watcher process which monitors the chain
%% changes and forwards new heights to the known metrics workers.
-module(aemon_mon).

-behaviour(gen_server).

%% API
-export([start_link/0]).

%% gen_server callbacks
-export([ init/1
        , handle_call/3
        , handle_cast/2
        , handle_info/2
        , terminate/2
        , code_change/3
        ]).

-record(st, {height = 0 :: non_neg_integer() }).

-define(METRIC_WORKERS, [aemon_mon_on_chain, aemon_mon_gen_stats]).

%% ==================================================================
%% API

start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% ==================================================================
%% gen_server callbacks

init(_) ->
    true = aec_events:subscribe(top_changed),
    {ok, Block} = aec_chain:top_key_block(),
    Height = aec_blocks:height(Block),
    {ok, #st{height = Height}}.

terminate(_Reason, _St) ->
    ok.

code_change(_FromVsn, St, _Extra) ->
    {ok, St}.

handle_call(_Req, _From, St) ->
    {reply, {error, unknown_request}, St}.

handle_cast(_Msg, St) ->
    {noreply, St}.

handle_info({gproc_ps_event, top_changed,
             #{info := #{block_type := key, block_hash := Hash, height := NewHeight}}},
            St = #st{height = Height}) ->
    Gens = lists:seq(Height, NewHeight-1),
    [notify(Gen) || Gen <- Gens],
    {ok, Block} = aec_chain:get_block(Hash),
    update_block_propagation_time(Block),
    update_chain_top_difficulty(Block),
    {ok, PrevBlock} = aec_chain:get_key_block_by_height(NewHeight-1),
    update_block_time_since_prev(key, Block, PrevBlock),
    {noreply, St#st{height = NewHeight}};
handle_info({gproc_ps_event, top_changed,
             #{info := #{block_type := micro, block_hash := Hash}}},
            St) ->
    {ok, Block} = aec_chain:get_block(Hash),
    update_block_propagation_time(Block),
    {ok, PrevBlock} = aec_chain:get_block(aec_blocks:prev_hash(Block)),
    update_block_time_since_prev(micro, Block, PrevBlock),
    {noreply, St};
handle_info(_Msg, St) ->
    {noreply, St}.

%% ==================================================================
%% internal functions

notify(Height) ->
    [ok = Worker:notify(Height) || Worker <- ?METRIC_WORKERS],
    ok.

update_block_propagation_time(Block) ->
    Type = aec_blocks:type(Block),
    Time = aec_blocks:time_in_msecs(Block),
    Now = aeu_time:now_in_msecs(),
    ok = aemon_metrics:block_propagation_time(Type, Now - Time).

update_chain_top_difficulty(Block) ->
    N = aec_blocks:difficulty(Block),
    ok = aemon_metrics:chain_top_difficulty(N).

update_block_time_since_prev(Type, Block, PrevBlock) ->
    Time = aec_blocks:time_in_msecs(Block),
    PrevTime = aec_blocks:time_in_msecs(PrevBlock),
    ok = aemon_metrics:block_time_since_prev(Type, Time - PrevTime).
