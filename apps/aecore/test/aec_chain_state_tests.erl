%%%-------------------------------------------------------------------
%%% @copyright (C) 2017, Aeternity Anstalt
%%% @doc
%%% EUnit tests for aec_chain_state
%%% @end
%%%-------------------------------------------------------------------

-module(aec_chain_state_tests).

-include_lib("eunit/include/eunit.hrl").
-include_lib("aeminer/include/aeminer.hrl").

%% Rewards calculation defines.
-define(TEST_MODULE, aec_chain_state).
-define(FEES, 10).
-define(MINER_REWARD2, 401).
-define(POW_REWARD1, 20).

-define(B1_FEES, 4 * ?FEES div 10).
-define(B2_FEES, ?FEES - ?B1_FEES).

%% Fork singalling defines.
-define(SIGNALLING_START_HEIGHT, 3).
-define(SIGNALLING_END_HEIGHT, 6).
-define(SIGNALLING_BLOCK_COUNT, 2).

-define(INFO_FIELD_AGAINST, 1).
-define(INFO_FIELD_SUPPORT, 2).
-define(INFO_FIELD_OTHER, 9999).

-define(VERSION_OLD, 5).
-define(VERSION_NEW, 6).

-define(TARGET_HIGH, ?HIGHEST_TARGET_SCI).
-define(TARGET_LOW, ?HIGHEST_TARGET_SCI - 1).

-define(FORK_CFG,
        #{signalling_start_height => ?SIGNALLING_START_HEIGHT,
          signalling_end_height   => ?SIGNALLING_END_HEIGHT,
          signalling_block_count  => ?SIGNALLING_BLOCK_COUNT,
          info_field              => ?INFO_FIELD_SUPPORT,
          version                 => ?VERSION_NEW}).

-define(BASIC_CHAIN_NEGATIVE_RESULT,
        #{1                        => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER},
          ?SIGNALLING_START_HEIGHT => #{version => ?VERSION_OLD, info => ?INFO_FIELD_AGAINST},
          ?SIGNALLING_END_HEIGHT   => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER}}).

-define(BASIC_CHAIN_POSITIVE_RESULT,
        #{1                        => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER},
          ?SIGNALLING_START_HEIGHT => #{version => ?VERSION_OLD, info => ?INFO_FIELD_SUPPORT},
          ?SIGNALLING_END_HEIGHT   => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER}}).

-define(FORK_CHAIN_COMMON,
        #{1                        => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER, target => ?TARGET_HIGH}}).

-define(FORK_CHAIN_LOW_DIFFICULTY_NEGATIVE_RESULT,
        #{?SIGNALLING_START_HEIGHT => #{version => ?VERSION_OLD, info => ?INFO_FIELD_AGAINST, target => ?TARGET_HIGH},
          ?SIGNALLING_END_HEIGHT   => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER, target => ?TARGET_HIGH}}).

-define(FORK_CHAIN_HIGH_DIFFICULTY_POSITIVE_RESULT,
        #{?SIGNALLING_START_HEIGHT => #{version => ?VERSION_OLD, info => ?INFO_FIELD_SUPPORT, target => ?TARGET_LOW},
          ?SIGNALLING_END_HEIGHT   => #{version => ?VERSION_OLD, info => ?INFO_FIELD_OTHER, target => ?TARGET_LOW}}).

%%%===================================================================
%%% Test cases - rewards
%%%===================================================================

rewards_calculation_test_() ->
    [{"Both miners are honest, previous key block is not genesis -> no locked",
      fun() ->
          {_B1Amt  = ?B1_FEES,
           _B2Amt  = ?B2_FEES + ?MINER_REWARD2,
           _Locked = 0} =
              rewards(false, false, false)
      end},
     {"Both miners are honest, previous key block is genesis -> miner1 fees are locked",
      fun() ->
          {_B1Amt  = 0,
           _B2Amt  = ?B2_FEES + ?MINER_REWARD2,
           _Locked = ?B1_FEES} =
              rewards(false, false, true)
      end},
     {"Miner1 is fraudulent, miner2 is honest, previous key block is genesis -> miner1 fees are locked, miner2 gets pow reward",
      fun() ->
          {_B1Amt  = 0,
           _B2Amt  = ?B2_FEES + ?MINER_REWARD2 + ?POW_REWARD1,
           _Locked = ?B1_FEES - ?POW_REWARD1} =
              rewards(true, false, true)
      end},
     {"Miner1 is fraudulent, miner2 is honest, previous key block is not genesis -> miner1 fees are locked, miner2 gets pow reward",
      fun() ->
          {_B1Amt  = 0,
           _B2Amt  = ?B2_FEES + ?MINER_REWARD2 + ?POW_REWARD1,
           _Locked = ?B1_FEES - ?POW_REWARD1} =
              rewards(true, false, false)
      end},
     {"Miner2 is fraudulent, miner1 is honest, previous key block is genesis -> miner2 fees are locked but not the coinbase reward; miner1 fees are also locked",
      fun() ->
          {_B1Amt  = 0,
           _B2Amt  = 0,
           _Locked = ?B1_FEES + ?B2_FEES + ?MINER_REWARD2} =
              rewards(false, true, true)
      end},
     {"Miner2 is fraudulent, miner1 is honest, previous key block is not genesis -> miner2 fees are locked but not the coinbase reward",
      fun() ->
          {_B1Amt  = ?B1_FEES,
           _B2Amt  = 0,
           _Locked = ?B2_FEES + ?MINER_REWARD2} =
              rewards(false, true, false)
      end},
     {"Both miners are fraudulent -> fees are locked but not the coinbase reward",
      fun() ->
          {_B1Amt  = 0,
           _B2Amt  = 0,
           _Locked = ?B1_FEES + ?B2_FEES + ?MINER_REWARD2} =
              rewards(true, true, true),
          {_B1Amt  = 0,
           _B2Amt  = 0,
           _Locked = ?B1_FEES + ?B2_FEES + ?MINER_REWARD2} =
              rewards(true, true, false)
      end},
     {"Small fees's amount result in a negative lock",
      fun() ->
          BlockReward = 42,
          FraudReward = 7,
          Fees        = 0,
          {_B1Amt  = 0,
           _B2Amt  = 49,
           _Locked = -7} =
              ?TEST_MODULE:calc_rewards(true, false, Fees,
                                        BlockReward, FraudReward, false)
      end},
     {"All fraudulent miner's fees are locked",
      fun() ->
          % fraudulent miner mined keyblock K2
          % amount that should be locked is:
          %   + 60% from K1 generation
          %   + 40% from K2 generation
          %   + K2's coinbase reward
          %   - K2's fraud reward

          % k1
          K1Fees = 100,
          K1FraudReward = 35,
          % k2
          K2Fees = 120,
          K2Coinbase = 1003,
          K2FraudReward = 36,
          % k3
          K3Coinbase = 1007,
          {_, 0, Locked1} =
              ?TEST_MODULE:calc_rewards(false, true, K1Fees,
                                        K2Coinbase, K1FraudReward, false),
          ?assertEqual(Locked1, K1Fees * 6 div 10 + K2Coinbase),
          {0, _, Locked2} =
              ?TEST_MODULE:calc_rewards(true, false, K2Fees,
                                        K3Coinbase, K2FraudReward, false),
          Locked = Locked1 + Locked2,
          ExpectedLocked = (K1Fees * 6 div 10)
                         + (K2Fees * 4 div 10)
                         + K2Coinbase
                         - K2FraudReward,
          ?assertEqual(Locked, ExpectedLocked)
      end}].

rewards(K1Fraud, K2Fraud, IsK1Genesis) ->
    ?TEST_MODULE:calc_rewards(K1Fraud, K2Fraud, ?FEES, ?MINER_REWARD2,
                              ?POW_REWARD1, IsK1Genesis).

%%%===================================================================
%%% Test cases - fork signalling
%%%===================================================================

chain_test_() ->
    {foreach,
     fun() ->
             meck:new(aec_trees, [passthrough]),
             meck:expect(aec_trees, perform_pre_transformations, fun(Trees, _, _) -> Trees end),
             aec_test_utils:mock_genesis_and_forks(),
             aec_test_utils:mock_governance(),
             {ok, _} = aec_db_error_store:start_link(),
             aec_test_utils:start_chain_db(),
             aec_test_utils:aec_keys_setup()
     end,
     fun(TmpDir) ->
             meck:unload(aec_trees),
             aec_test_utils:aec_keys_cleanup(TmpDir),
             aec_test_utils:stop_chain_db(),
             ok = aec_db_error_store:stop(),
             aec_test_utils:unmock_governance(),
             aec_test_utils:unmock_genesis_and_forks()
     end,
     [{"Basic chain negative result test, start before signalling interval",
       fun() -> basic_chain(start_before_signalling_interval, ?BASIC_CHAIN_NEGATIVE_RESULT, false) end},
      {"Basic chain positive result test, start before signalling interval",
       fun() -> basic_chain(start_before_signalling_interval, ?BASIC_CHAIN_POSITIVE_RESULT, true) end},
      {"Basic chain negative result, start at last signalling block",
       fun() -> basic_chain(start_at_last_signalling_block, ?BASIC_CHAIN_NEGATIVE_RESULT, false) end},
      {"Basic chain positive result, start at last signalling block",
       fun() -> basic_chain(start_at_last_signalling_block, ?BASIC_CHAIN_POSITIVE_RESULT, true) end},
      {"Basic chain negative result, start between first and last signalling block",
       fun() -> basic_chain(start_between_first_and_last_signalling_block, ?BASIC_CHAIN_NEGATIVE_RESULT, false) end},
      {"Basic chain positive result, start between first and last signalling block",
        fun() -> basic_chain(start_between_first_and_last_signalling_block, ?BASIC_CHAIN_POSITIVE_RESULT, true) end},
      {"Fork chain at signalling start block",
       fun() -> fork_chain(fork_at_signalling_start_block) end}
     ]}.

%% [0] --- [1] --- [2] --- [3] --- [4] --- [5] ---
%%                 H1      HS            HE - 1
%%
%% start_before_signalling_interval - best case scenario. Node keeps count of
%% signal for each added key block starting at first signalling block.
basic_chain(start_before_signalling_interval, BlockCfg, ExpectedForkResult) ->
    %% SIGNALLING_END_HEIGHT blocks are needed to be generated (including the genesis),
    %% so the chain ends up at HE - 1 height where it's possible to find out
    %% the fork signalling result.
    [B0, B1, B2, B3, B4, B5] =
        aec_test_utils:gen_blocks_only_chain(?SIGNALLING_END_HEIGHT, BlockCfg),

    application:set_env(aecore, fork, ?FORK_CFG),

    ok = insert_block(B0),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(B0, ?FORK_CFG)),
    ok = insert_block(B1),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(B1, ?FORK_CFG)),
    ok = insert_block(B2),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(B2, ?FORK_CFG)),
    ok = insert_block(B3),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(B3, ?FORK_CFG)),
    ok = insert_block(B4),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(B4, ?FORK_CFG)),
    ok = insert_block(B5),
    ?assertEqual({ok, ExpectedForkResult}, ?TEST_MODULE:get_fork_result(B5, ?FORK_CFG)),

    application:unset_env(aecore, fork),
    ok;


%% [0] --- [1] --- [2] --- [3] --- [4] --- [5] ---
%%                 H1      HS            HE - 1
%%                                          ^
%%
%% start_at_last_signalling_block - the node is started at the last signalling
%% block and there is no signal count in the database. All the key blocks need
%% to be traversed back to signalling start to get the count.
basic_chain(start_at_last_signalling_block, BlockCfg, ExpectedForkResult) ->
    [B0, B1, B2, B3, B4, B5] =
        aec_test_utils:gen_blocks_only_chain(?SIGNALLING_END_HEIGHT, BlockCfg),
    write_blocks_to_chain([B0, B1, B2, B3, B4, B5]),

    application:set_env(aecore, fork, ?FORK_CFG),

    ?assertEqual({ok, ExpectedForkResult}, ?TEST_MODULE:get_fork_result(B5, ?FORK_CFG)),

    application:unset_env(aecore, fork),
    ok;

%% [0] --- [1] --- [2] --- [3] --- [4] --- [5] ---
%%                 H1      HS            HE - 1
%%                                  ^
%%
%% start_between_first_and_last_signalling_block - the node is started within
%% the signalling interval and there is no signal count in the db. All the key
%% blocks need to be traversed back to signalling start to get the count.
basic_chain(start_between_first_and_last_signalling_block, BlockCfg, ExpectedForkResult) ->
     [B0, B1, B2, B3, B4, B5] =
        aec_test_utils:gen_blocks_only_chain(?SIGNALLING_END_HEIGHT, BlockCfg),
    write_blocks_to_chain([B0, B1, B2, B3, B4]),

    application:set_env(aecore, fork, ?FORK_CFG),

    ok = insert_block(B5),
    ?assertEqual({ok, ExpectedForkResult}, ?TEST_MODULE:get_fork_result(B5, ?FORK_CFG)),

    application:unset_env(aecore, fork),
    ok.

%%                         [3] --- [4] --- [5] ---  <- High difficulty
%%                          |
%% [0] --- [1] --- [2] --- [3] --- [4] --- [5] ---  <- Low difficulty
%%                 H1      HS            HE - 1
%%
%% Low difficulty chain has fork signalling result false.
%% Hight difficulty chain has fork signalling result true.
%% There is a fork at signalling start height. The low difficulty chain ends up
%% at the last signalling block, then the high difficulty chain ends up at the
%% same height and the fork signalling results are different for the two chains.
fork_chain(fork_at_signalling_start_block) ->
    CommonChain = aec_test_utils:gen_block_chain_with_state(3, ?FORK_CHAIN_COMMON),
    [B0, B1, B2] = aec_test_utils:blocks_only_chain(CommonChain),
    MinerAccount = aec_blocks:miner(B1),

    application:set_env(aecore, fork, ?FORK_CFG),

    ok = insert_block(B0),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(B0, ?FORK_CFG)),
    ok = insert_block(B1),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(B1, ?FORK_CFG)),
    ok = insert_block(B2),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(B2, ?FORK_CFG)),

    %% Easy chain fork
    EasyChainBlockCfg = maps:merge(?FORK_CHAIN_COMMON, ?FORK_CHAIN_LOW_DIFFICULTY_NEGATIVE_RESULT),
    EasyChain =
        aec_test_utils:extend_block_chain_with_key_blocks(CommonChain, 3, MinerAccount, MinerAccount, EasyChainBlockCfg),
    [EB3, EB4, EB5] = aec_test_utils:blocks_only_chain(EasyChain),

    ok = insert_block(EB3),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(EB3, ?FORK_CFG)),
    ok = insert_block(EB4),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(EB4, ?FORK_CFG)),
    ok = insert_block(EB5),
    ?assertEqual({ok, false}, ?TEST_MODULE:get_fork_result(EB5, ?FORK_CFG)),

    %% Hard chain fork
    HardChainBlockCfg = maps:merge(?FORK_CHAIN_COMMON, ?FORK_CHAIN_HIGH_DIFFICULTY_POSITIVE_RESULT),
    HardChain =
        aec_test_utils:extend_block_chain_with_key_blocks(CommonChain, 3, MinerAccount, MinerAccount, HardChainBlockCfg),
    [HB3, HB4, HB5] = aec_test_utils:blocks_only_chain(HardChain),

    ok = insert_block(HB3),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(HB3, ?FORK_CFG)),
    ok = insert_block(HB4),
    ?assertEqual({error, not_last_signalling_block}, ?TEST_MODULE:get_fork_result(HB4, ?FORK_CFG)),
    ok = insert_block(HB5),
    ?assertEqual({ok, true}, ?TEST_MODULE:get_fork_result(HB5, ?FORK_CFG)),

    %% The current top is a block from the hard chain
    ?assertEqual(HB5, aec_chain:top_block()),

    application:unset_env(aecore, fork),
    ok.

throughput_test_() ->
    {setup,
     fun() ->
             aec_test_utils:start_chain_db(),
             aec_test_utils:mock_genesis_and_forks(),
             aec_test_utils:dev_reward_setup(true, true, 100),
             TmpDir = aec_test_utils:aec_keys_setup(),
             {ok, PubKey} = aec_keys:pubkey(),
             ok = application:set_env(aecore, beneficiary, aeser_api_encoder:encode(account_pubkey, PubKey)),
             TmpDir
     end,
     fun(TmpDir) ->
             ok = application:unset_env(aecore, beneficiary),
             aec_test_utils:unmock_genesis_and_forks(),
             aec_test_utils:stop_chain_db(),
             aec_test_utils:aec_keys_cleanup(TmpDir)
     end,
     [{"Throughput test building chain with 1000 blocks in ram",
       fun() ->
               %% Setup
               TotalBlockCount = 1000,
               TestFun = fun(B) -> {ok, _} = aec_chain_state:insert_block(B) end,
               Blocks = aec_test_utils:gen_blocks_only_chain(TotalBlockCount),
               run_throughput_test(TestFun, Blocks, "in ram"),

               ok
       end}
     ]}.

run_throughput_test(TestFun, Blocks, Info) ->
    InsertBlockFun = fun(B0, AccTime) ->
                             T0 = erlang:system_time(microsecond),
                             TestFun(B0),
                             T1 = erlang:system_time(microsecond),
                             [T1 - T0 | AccTime]
                     end,

    %% Run timings
    Timings = lists:foldl(InsertBlockFun, [], Blocks),

    %% Prepare and print data
    TotalRuntime = lists:sum(Timings),
    [Min | _] = TimingsSorted = lists:sort(Timings),
    Max = lists:last(TimingsSorted),
    Range = Max - Min,
    Mean = TotalRuntime div length(Timings),
    Median = lists:nth(ceil(length(Timings) / 2), TimingsSorted),
    Counts = lists:foldl(
               fun(N, Acc) ->
                       case lists:keyfind(N, 1, Acc) of
                           false ->
                               [{N, 1} | Acc];
                           {N, Count} ->
                               lists:keyreplace(N, 1, Acc, {N, Count + 1})
                       end
               end, [], Timings),
    [{Mode, _} | _] = lists:keysort(2, Counts),

    io:format(user,
              "~nThroughput testing results (in microseconds) " ++ Info ++ "~n~n"
              "# of blocks inserted\t= ~p~n"
              "Total runtime\t\t= ~p~n~n"
              "Min\t= ~p~n"
              "Max\t= ~p~n"
              "Mean\t= ~p~n"
              "Mode\t= ~p~n"
              "Range\t= ~p~n"
              "Median\t= ~p~n",
              [length(Blocks), TotalRuntime, Min, Max, Mean, Mode, Range, Median]
             ),
    ok.

write_blocks_to_chain([H | T]) ->
    ok = insert_block(H),
    write_blocks_to_chain(T);
write_blocks_to_chain([]) ->
    ok.

insert_block(Block) ->
    insert_block_ret(aec_chain_state:insert_block(Block)).

insert_block_ret({ok,_}     ) -> ok;
insert_block_ret({pof,Pof,_}) -> {pof,Pof};
insert_block_ret(Other      ) -> Other.
