% This library is a limited port of: 
% https://github.com/marcelklehr/changesets

-module(ot).

-export([unpack/1, pack/1, apply_to/2, transform/2, sequencify/1]).

-type op_type() :: ins | del.
-type op_idx() :: non_neg_integer().
-type op_len() :: non_neg_integer().
-type op_text() :: iolist().
-type op_size() :: non_neg_integer().
-type op_acs() :: non_neg_integer().
-type op() :: {op_type(), op_idx(), op_len(), op_text(), op_size(), op_acs()}.
-type op_list() :: [op() | {eq, op_acs()}].
-type op_list_strict() :: [op()].
-type utf_string() :: iodata() | unicode:charlist().

-spec apply_to(op() | op_list(), Body :: utf_string()) -> utf_string().
apply_to([], Body) -> Body;
apply_to(Ops, Body) when is_list(Ops) ->
  lists:foldl(fun apply_to/2, Body, sequencify(Ops));

% Insert operation
apply_to({ins, Idx, Len, Text, _Size, _Acs}, Body) ->
  % todo: more informative error message
  Len = bin_utf:len(Body), % check text length
  iolist_to_binary([
    bin_utf:substr(Body, 0, Idx),
    Text,
    bin_utf:substr(Body, Idx)
  ]);
% Delete operation
apply_to({del, Idx, Len, Text, Size, _Acs}, Body) ->
  Len = bin_utf:len(Body), % check text length
  Text = bin_utf:substr(Body, Idx, Size), % check removed text
  iolist_to_binary([
    bin_utf:substr(Body, 0, Idx),
    bin_utf:substr(Body, Idx + Size)
  ]);
% Equal operation
apply_to({eq, _Acs}, Body) -> Body.

% Transforms all contained operations against each
% other in sequence and returns an array of those new operations
sequencify([]) -> [];
sequencify(Ops) -> sequencify(Ops, [], []).
sequencify([], Acc, _Prev) ->
  lists:reverse(Acc);
sequencify([Op|Rest], Acc, Prev) ->
  % transform against all previous ops
  NewAcc = lists:append(transform([Op], lists:reverse(Prev)), Acc),
  sequencify(Rest, NewAcc, [Op | Prev]).

transform([], []) -> [];
transform(Ops, []) -> Ops;
transform([], _Ops) -> [];
transform(Ops=[_|_], AgainstOps=[_|_]) ->
  Map = fun(AgainstOp, EachOp) ->
    transform(EachOp, AgainstOp)
  end,
  Transformed = [ lists:foldl(Map, Op, sequencify(AgainstOps)) || Op <- Ops ],
  lists:flatten(Transformed);

% 'abc' =>  0:+x('xabc') | 3:+x('abcx')
% 'xabcx'
transform({ins, Idx, Len, Text, Size, Acs}, {ins, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx < Idx2 ->
    {ins, Idx, Len + Size2, Text, Size, Acs};
% 'abc'=>   1:+x('axbc') | 1:+y('aybc')
% 'ayxbc'  -- depends on the accessory (the tie breaker)
transform({ins, Idx, Len, Text, Size, Acs}, {ins, Idx, _Len2, _Text2, Size2, Acs2})
  when Acs < Acs2 ->
    {ins, Idx, Len + Size2, Text, Size, Acs};
% 'abc'=>   1:+x('axbc') | 0:+x('xabc')
% 'xaxbc'
transform({ins, Idx, Len, Text, Size, Acs}, {ins, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx2 =< Idx ->
    {ins, Idx + Size2, Len + Size2, Text, Size, Acs};
% 'abc'=>  1:+x('axbc') | 2:-1('ab')
% 'axb'
transform({ins, Idx, Len, Text, Size, Acs}, {del, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx < Idx2 ->
    {ins, Idx, Len - Size2, Text, Size, Acs};
% 'abc'=>  1:+x('axbc') | 1:-1('ac')
% 'axb'
transform({ins, Idx, Len, Text, Size, Acs}, {del, Idx, _Len2, _Text2, Size2, _Acs2}) ->
  {ins, Idx, Len - Size2, Text, Size, Acs};
% 'abc'=> 2:+x('abxc') | 0:-2('c')
% 'xc'
transform({ins, Idx, Len, Text, Size, Acs}, {del, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx2 < Idx ->
    {ins, max(Idx - Size2, Idx2), Len - Size2, Text, Size, Acs};
% Insert vs Equal
transform(Op={ins, _Idx, _Len, _Text, _Size, _Acs}, {eq, _Acs2}) ->  Op;

% 'abc' =>  0:-2('c') | 1:-1('ac')
% 'c'
transform({del, Idx, Len, Text, Size, Acs}, {del, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx < Idx2 ->
    % if the other operation already deleted some of the characters
    % in my range, don't delete them again!
    StartOfOther = min(Idx2 - Idx, Size),
    NewText = iolist_to_binary([
      bin_utf:substr(Text, 0, StartOfOther),
      bin_utf:substr(Text, StartOfOther + Size2)
    ]),
    {del, Idx, Len - Size2, NewText, bin_utf:len(NewText), Acs};
% 'abc'=>   1:-1('ac') | 1:-2('a')
% 'a'
transform({del, Idx, _Len, _Text, Size, Acs}, {del, Idx, _Len2, _Text2, Size2, _Acs2})
  when Size =< Size2 ->
    % if the other operation already deleted some the characters
    % in my range, don't delete them again!
    {eq, Acs};
transform({del, Idx, Len, Text, _Size, Acs}, {del, Idx, _Len2, _Text2, Size2, _Acs2}) ->
  % the other deletion's range is shorter than mine
  NewText = bin_utf:substr(Text, Size2),
  {del, Idx, Len - Size2, NewText, bin_utf:len(NewText), Acs};
% 'abcd'=>   2:-1('abd') | 0:-3('d')
% 'd'
transform({del, Idx, Len, Text, Size, Acs}, {del, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx2 < Idx ->
    % overlap of `change`, starting at `this.pos`
    Overlap = Idx2 + Size2 - Idx,
    if Overlap >= Len -> {eq, Acs};
       Overlap > 0 ->
        NewText = bin_utf:substr(Text, Overlap),
        {del, Idx2, Len - Size2, NewText, bin_utf:len(NewText), Acs};
       true ->
        {del, Idx - Size2, Len - Size2, Text, Size, Acs}
    end;
% 'abc' =>  0:-1('bc') | 3:+x('abcx')
% 'bcx'
transform({del, Idx, Len, Text, Size, Acs}, {ins, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx < Idx2 andalso Idx + Size > Idx2 ->
    % An insert is done within our deletion range
    % -> split it in to
    FirstHalfLen = Idx2 - Idx,
    NewText1 = bin_utf:substr(Text, 0, FirstHalfLen),
    NewText2 = bin_utf:substr(Text, FirstHalfLen),
    [
      {del, Idx, Len + Size2, NewText1, bin_utf:len(NewText1), Acs},
      {del, Idx2 + Size2, Len + Size2, NewText2, bin_utf:len(NewText2), Acs}
    ];
transform({del, Idx, Len, Text, Size, Acs}, {ins, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx < Idx2 ->
    {del, Idx, Len + Size2, Text, Size, Acs};
% 'abc'=>   1:-1('ac') | 1:+x('axbc')
% 'axc'
transform({del, Idx, Len, Text, Size, Acs}, {ins, Idx, _Len2, _Text2, Size2, _Acs2}) ->
  {del, Idx + Size2, Len + Size2, Text, Size, Acs};
% 'abc'=>   2:-1('ab') | 0:+x('xabc')
% 'xab'
transform({del, Idx, Len, Text, Size, Acs}, {ins, Idx2, _Len2, _Text2, Size2, _Acs2})
  when Idx2 < Idx ->
    {del, Idx + Size2, Len + Size2, Text, Size, Acs};
% Delete vs Equal
transform(Op={del, _Idx, _Len, _Text, _Size, _Acs}, {eq, _Acs2}) ->  Op;
% Equal vs Anything
transform(Op={eq, _Acs}, _) ->  Op.

% -0:6:w1:4-4:6:hq:4

-spec pack(op_list()) -> binary().
pack([]) -> <<>>;
pack(Ops) ->
  iolist_to_binary([begin
    TypeBin = case Type of
      ins -> <<"+">>;
      del -> <<"-">>
    end,
    IdxBin = pack_base36(Idx),
    Chunks = [
      <<TypeBin/binary, IdxBin/binary>>,
      pack_base36(Len),
      pack_text(Text),
      pack_base36(Acs)
    ],
    <<":", OpBin/binary>> = << <<":", C/binary>> || C <- Chunks >>,
    OpBin
  end || {Type, Idx, Len, Text, _Size, Acs} <- Ops]).

-spec pack_base36(non_neg_integer()) -> binary().
pack_base36(Integer) ->
  list_to_binary(io_lib:format("~.36b", [Integer])).

-spec pack_text(utf_string()) -> binary().
pack_text(Text) ->
  {ok, Re1} = re:compile("%"),
  {ok, Re2} = re:compile(":"),
  Text1 = re:replace(Text, Re1, <<"%25">>, [global]),
  Text2 = re:replace(Text1, Re2, <<"%3A">>, [global]),
  iolist_to_binary(Text2).

-spec unpack(utf_string()) -> op_list_strict().
unpack(<<>>) -> [];
unpack(String) ->
  {ok, Re} = re:compile("(\\+|-)(\\w+):(\\w+):([^:]+?):(\\w+)"),
  {match, Matches} = re:run(String, Re,
    [global, notempty, {capture, all_but_first, binary}]),
  [begin
    Text = unpack_text(lists:nth(4, Match)),
    {
      case lists:nth(1, Match) of
        <<"+">> -> ins;
        <<"-">> -> del
      end, % type
      unpack_base36(lists:nth(2, Match)), % index
      unpack_base36(lists:nth(3, Match)), % length
      Text,
      bin_utf:len(Text), % size
      unpack_base36(lists:nth(5, Match)) % accessory
    }
  end || Match <- Matches].

-spec unpack_base36(binary()) -> non_neg_integer().
unpack_base36(Binary) ->
  list_to_integer(binary_to_list(Binary), 36).

-spec unpack_text(utf_string()) -> binary().
unpack_text(Text) ->
  {ok, Re1} = re:compile("%3A"),
  {ok, Re2} = re:compile("%25"),
  Text1 = re:replace(Text, Re1, <<":">>, [global]),
  Text2 = re:replace(Text1, Re2, <<"%">>, [global]),
  iolist_to_binary(Text2).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

-define(assert_transform (Result, Text, ChA, ChB),
  ?assertEqual(Result, transform_text(Text, ChA, ChB))).

insert_onto_insert_test() ->
  % Insert onto Insert; o1.pos < o2.pos
  ?assert_transform(<<"a123b">>, <<"123">>, <<"+0:3:a:0">>, <<"+3:3:b:1">>),
  % Insert onto Insert; o1.pos = o2.pos
  ?assert_transform(<<"1ab23">>, <<"123">>, <<"+1:3:a:0">>, <<"+1:3:b:1">>),
  % Insert onto Insert; o2.pos < o1.pos
  ?assert_transform(<<"b12a3">>, <<"123">>, <<"+2:3:a:0">>, <<"+0:3:b:1">>),
  ok.

insert_onto_delete_test() ->
  % Insert onto Delete; o1.pos < o2.pos
  ?assert_transform(<<"1a2">>, <<"123">>, <<"+1:3:a:0">>, <<"-2:3:3:1">>),
  % Insert onto Delete; o1.pos = o2.pos
  ?assert_transform(<<"1a3">>, <<"123">>, <<"+1:3:a:0">>, <<"-1:3:2:1">>),
  % Insert onto Delete; o2.pos+len = o1.pos
  ?assert_transform(<<"a3">>, <<"123">>, <<"+2:3:a:0">>, <<"-0:3:12:1">>),
  % Insert onto Delete; o2.pos < o1.pos
  ?assert_transform(<<"2a3">>, <<"123">>, <<"+2:3:a:0">>, <<"-0:3:1:1">>),
  % Insert onto Delete; o1.pos < o2.pos+len
  ?assert_transform(<<"1a">>, <<"123">>, <<"+2:3:a:0">>, <<"-1:3:23:1">>),
  % Insert onto Delete; o2.pos < o1 < o2.pos+len
  ?assert_transform(<<"a">>, <<"123">>, <<"+2:3:a:0">>, <<"-0:3:123:1">>),
  ok.

delete_onto_delete_test() ->
  % Delete onto Delete; o2.pos+len < o1.pos
  ?assert_transform(<<"24">>, <<"1234">>, <<"-2:4:3:0">>, <<"-0:4:1:1">>),
  % Delete onto Delete; o1.pos < o2.pos
  ?assert_transform(<<"24">>, <<"1234">>, <<"-0:4:1:0">>, <<"-2:4:3:1">>),
  % Delete onto Delete; something at the end of my range has already been deleted
  ?assert_transform(<<"3">>, <<"123">>, <<"-0:3:12:0">>, <<"-1:3:2:1">>),
  % Delete onto Delete; something at the beginning of my range has already been deleted
  ?assert_transform(<<"3">>, <<"123">>, <<"-0:3:12:0">>, <<"-0:3:1:1">>),
  % Delete onto Delete; something in the middle of my range has already been deleted
  ?assert_transform(<<"4">>, <<"1234">>, <<"-0:4:123:0">>, <<"-1:4:2:1">>),
  % Delete onto Delete; my whole range has already been deleted ('twas at the beginning of the other change's range)
  ?assert_transform(<<"1">>, <<"123">>, <<"-1:3:2:0">>, <<"-1:3:23:1">>),
  % Delete onto Delete; my whole range has already been deleted ('twas at the end of the other change's range)
  ?assert_transform(<<"1">>, <<"123">>, <<"-2:3:3:0">>, <<"-1:3:23:1">>),
  % Delete onto Delete; my whole range has already been deleted ('twas in the middle of the other change's range)
  ?assert_transform(<<"4">>, <<"1234">>, <<"-1:4:2:0">>, <<"-0:4:123:1">>),
  ok.

delete_onto_insert_test() ->
  % Delete onto Insert; o1.pos+len < o2.pos
  ?assert_transform(<<"23b">>, <<"123">>, <<"-0:3:1:0">>, <<"+3:3:b:1">>),
  % Delete onto Insert; o1.pos < o2.pos < o2.pos+len < o1.pos+len
  ?assert_transform(<<"b3">>, <<"123">>, <<"-0:3:12:0">>, <<"+1:3:b:1">>),
  % Delete onto Insert; o1.pos = o2.pos , o1.len = o2.len
  ?assert_transform(<<"1b3">>, <<"123">>, <<"-1:3:2:0">>, <<"+1:3:b:1">>),
  % Delete onto Insert; o1.pos = o2.pos, o2.len < o1.len
  ?assert_transform(<<"1b">>, <<"123">>, <<"-1:3:23:0">>, <<"+1:3:b:1">>),
  % Delete onto Insert; o1.pos = o2.pos, o1.len < o2.len
  ?assert_transform(<<"1bbb">>, <<"123">>, <<"-1:3:23:0">>, <<"+1:3:bbb:1">>),
  % Delete onto Insert; o2.pos+len < o1.pos
  ?assert_transform(<<"b12">>, <<"123">>, <<"-2:3:3:0">>, <<"+0:3:b:1">>),
  ok.

insert_onto_nothing_test() ->
  ?assert_transform(<<"1a2b3c">>, <<"123">>, <<"+1:3:a:0+2:3:b:0+3:3:c:0">>, <<>>),
  ok.

accessories_test() ->
  Text = <<"1234">>,
  ChA = unpack(<<"+4:4:b:521">>), % 1234b
  ChB = unpack(<<"+4:4:a:834">>), % 1234a
  % should cause the same outcome ragardless of the transformation order
  Text1 = apply_to(transform(ChA, ChB), apply_to(ChB, Text)),
  Text2 = apply_to(transform(ChB, ChA), apply_to(ChA, Text)),
  ?assertEqual(Text1, Text2),
  ok.

transform_text(Text, PackChA, PackChB) ->
  ChA = unpack(PackChA),
  ChB = unpack(PackChB),
  TextB = apply_to(ChB, Text),
  ChAB = transform(ChA, ChB),
  apply_to(ChAB, TextB).

-endif.
