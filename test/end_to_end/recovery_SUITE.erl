-module(recovery_SUITE).
-include_lib("common_test/include/ct.hrl").
-include("include/leveled.hrl").
-export([all/0]).
-export([retain_strategy/1,
            aae_bustedjournal/1
            ]).

all() -> [
            retain_strategy,
            aae_bustedjournal
            ].

retain_strategy(_Config) ->
    RootPath = testutil:reset_filestructure(),
    BookOpts = #bookie_options{root_path=RootPath,
                                cache_size=1000,
                                max_journalsize=5000000,
                                reload_strategy=[{?RIAK_TAG, retain}]},
    BookOptsAlt = BookOpts#bookie_options{max_run_length=8,
                                            max_journalsize=100000},
    {ok, Spcl3, LastV3} = rotating_object_check(BookOpts, "Bucket3", 800),
    ok = restart_from_blankledger(BookOpts, [{"Bucket3", Spcl3, LastV3}]),
    {ok, Spcl4, LastV4} = rotating_object_check(BookOpts, "Bucket4", 1600),
    ok = restart_from_blankledger(BookOpts, [{"Bucket3", Spcl3, LastV3},
                                                {"Bucket4", Spcl4, LastV4}]),
    {ok, Spcl5, LastV5} = rotating_object_check(BookOpts, "Bucket5", 3200),
    ok = restart_from_blankledger(BookOptsAlt, [{"Bucket3", Spcl3, LastV3},
                                                {"Bucket5", Spcl5, LastV5}]),
    {ok, Spcl6, LastV6} = rotating_object_check(BookOpts, "Bucket6", 6400),
    ok = restart_from_blankledger(BookOpts, [{"Bucket3", Spcl3, LastV3},
                                                {"Bucket4", Spcl4, LastV4},
                                                {"Bucket5", Spcl5, LastV5},
                                                {"Bucket6", Spcl6, LastV6}]),
    testutil:reset_filestructure().



aae_bustedjournal(_Config) ->
    RootPath = testutil:reset_filestructure(),
    StartOpts = #bookie_options{root_path=RootPath,
                                 max_journalsize=20000000},
    {ok, Bookie1} = leveled_bookie:book_start(StartOpts),
    {TestObject, TestSpec} = testutil:generate_testobject(),
    ok = leveled_bookie:book_riakput(Bookie1, TestObject, TestSpec),
    testutil:check_forobject(Bookie1, TestObject),
    GenList = [2],
    _CLs = testutil:load_objects(20000, GenList, Bookie1, TestObject,
                                fun testutil:generate_objects/2),
    ok = leveled_bookie:book_close(Bookie1),
    {ok, FNsA_J} = file:list_dir(RootPath ++ "/journal/journal_files"),
    {ok, Regex} = re:compile(".*\.cdb"),
    CDBFiles = lists:foldl(fun(FN, Acc) -> case re:run(FN, Regex) of
                                                nomatch ->
                                                    Acc;
                                                _ ->
                                                    [FN|Acc]
                                            end
                                            end,
                                [],
                                FNsA_J),
    [HeadF|_Rest] = CDBFiles,
    io:format("Selected Journal for corruption of ~s~n", [HeadF]),
    {ok, Handle} = file:open(RootPath ++ "/journal/journal_files/" ++ HeadF,
                                [binary, raw, read, write]),
    lists:foreach(fun(X) ->
                        Position = X * 1000 + 2048,
                        ok = file:pwrite(Handle, Position, <<0:8/integer>>)
                        end,
                    lists:seq(1, 1000)),
    ok = file:close(Handle),
    {ok, Bookie2} = leveled_bookie:book_start(StartOpts),
    
    {async, KeyF} = leveled_bookie:book_returnfolder(Bookie2,
                                                        {keylist, ?RIAK_TAG}),
    KeyList = KeyF(),
    20001 = length(KeyList),
    HeadCount = lists:foldl(fun({B, K}, Acc) ->
                                    case leveled_bookie:book_riakhead(Bookie2,
                                                                        B,
                                                                        K) of
                                        {ok, _} -> Acc + 1;
                                        not_found -> Acc
                                    end
                                    end,
                                0,
                                KeyList),
    20001 = HeadCount,
    GetCount = lists:foldl(fun({B, K}, Acc) ->
                                    case leveled_bookie:book_riakget(Bookie2,
                                                                        B,
                                                                        K) of
                                        {ok, _} -> Acc + 1;
                                        not_found -> Acc
                                    end
                                    end,
                                0,
                                KeyList),
    true = GetCount > 19000,
    true = GetCount < HeadCount,
    
    {async, HashTreeF1} = leveled_bookie:book_returnfolder(Bookie2,
                                                            {hashtree_query,
                                                                ?RIAK_TAG,
                                                                false}),
    KeyHashList1 = HashTreeF1(),
    20001 = length(KeyHashList1),
    {async, HashTreeF2} = leveled_bookie:book_returnfolder(Bookie2,
                                                            {hashtree_query,
                                                                ?RIAK_TAG,
                                                                check_presence}),
    KeyHashList2 = HashTreeF2(),
    % The file is still there, and the hashtree is not corrupted
    KeyHashList2 = KeyHashList1,
    % Will need to remove the file or corrupt the hashtree to get presence to
    % fail
    
    ok = leveled_bookie:book_close(Bookie2),
    testutil:reset_filestructure().


rotating_object_check(BookOpts, B, NumberOfObjects) ->
    {ok, Book1} = leveled_bookie:book_start(BookOpts),
    {KSpcL1, V1} = testutil:put_indexed_objects(Book1, B, NumberOfObjects),
    ok = testutil:check_indexed_objects(Book1,
                                        B,
                                        KSpcL1,
                                        V1),
    {KSpcL2, V2} = testutil:put_altered_indexed_objects(Book1,
                                                        B,
                                                        KSpcL1,
                                                        false),
    ok = testutil:check_indexed_objects(Book1,
                                        B,
                                        KSpcL1 ++ KSpcL2,
                                        V2),
    {KSpcL3, V3} = testutil:put_altered_indexed_objects(Book1,
                                                        B,
                                                        KSpcL2,
                                                        false),
    ok = leveled_bookie:book_close(Book1),
    {ok, Book2} = leveled_bookie:book_start(BookOpts),
    ok = testutil:check_indexed_objects(Book2,
                                        B,
                                        KSpcL1 ++ KSpcL2 ++ KSpcL3,
                                        V3),
    {KSpcL4, V4} = testutil:put_altered_indexed_objects(Book2,
                                                        B,
                                                        KSpcL3,
                                                        false),
    io:format("Bucket complete - checking index before compaction~n"),
    ok = testutil:check_indexed_objects(Book2,
                                        B,
                                        KSpcL1 ++ KSpcL2 ++ KSpcL3 ++ KSpcL4,
                                        V4),
    
    ok = leveled_bookie:book_compactjournal(Book2, 30000),
    F = fun leveled_bookie:book_islastcompactionpending/1,
    lists:foldl(fun(X, Pending) ->
                        case Pending of
                            false ->
                                false;
                            true ->
                                io:format("Loop ~w waiting for journal "
                                    ++ "compaction to complete~n", [X]),
                                timer:sleep(20000),
                                F(Book2)
                        end end,
                    true,
                    lists:seq(1, 15)),
    io:format("Waiting for journal deletes~n"),
    timer:sleep(20000),
    
    io:format("Checking index following compaction~n"),
    ok = testutil:check_indexed_objects(Book2,
                                        B,
                                        KSpcL1 ++ KSpcL2 ++ KSpcL3 ++ KSpcL4,
                                        V4),
    
    ok = leveled_bookie:book_close(Book2),
    {ok, KSpcL1 ++ KSpcL2 ++ KSpcL3 ++ KSpcL4, V4}.
    
    
restart_from_blankledger(BookOpts, B_SpcL) ->
    leveled_penciller:clean_testdir(BookOpts#bookie_options.root_path ++
                                    "/ledger"),
    {ok, Book1} = leveled_bookie:book_start(BookOpts),
    io:format("Checking index following restart~n"),
    lists:foreach(fun({B, SpcL, V}) ->
                        ok = testutil:check_indexed_objects(Book1, B, SpcL, V)
                        end,
                    B_SpcL),
    ok = leveled_bookie:book_close(Book1),
    ok.