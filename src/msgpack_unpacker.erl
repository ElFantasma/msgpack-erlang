%%
%% MessagePack for Erlang
%%
%% Copyright (C) 2009-2013 UENISHI Kota
%%
%%    Licensed under the Apache License, Version 2.0 (the "License");
%%    you may not use this file except in compliance with the License.
%%    You may obtain a copy of the License at
%%
%%        http://www.apache.org/licenses/LICENSE-2.0
%%
%%    Unless required by applicable law or agreed to in writing, software
%%    distributed under the License is distributed on an "AS IS" BASIS,
%%    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%%    See the License for the specific language governing permissions and
%%    limitations under the License.
%%

-module(msgpack_unpacker).

-export([unpack_stream/2, map_unpacker/1]).

-include("msgpack.hrl").
-include_lib("eunit/include/eunit.hrl").


-export([unpack_map/3, unpack_map_jiffy/3, unpack_map_jsx/3]).

%% unpack them all
-spec unpack_stream(Bin::binary(), ?OPTION{}) -> {msgpack:object(), binary()} | no_return().
%% ATOMS
unpack_stream(<<16#C0, Rest/binary>>, _) ->
    {null, Rest};
unpack_stream(<<16#C2, Rest/binary>>, _) ->
    {false, Rest};
unpack_stream(<<16#C3, Rest/binary>>, _) ->
    {true, Rest};

%% Raw bytes
unpack_stream(<<16#C4, L:8/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Opt) ->
    {maybe_bin(V, Opt), Rest};
unpack_stream(<<16#C5, L:16/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Opt) ->
    {maybe_bin(V, Opt), Rest};
unpack_stream(<<16#C6, L:32/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Opt) ->
    {maybe_bin(V, Opt), Rest};

%% Floats
unpack_stream(<<16#CA, V:32/float-unit:1, Rest/binary>>, _) ->
    {V, Rest};
unpack_stream(<<16#CA, 0:1, 16#FF:8, 0:23, Rest/binary>>, _) ->
    {positive_infinity, Rest};
unpack_stream(<<16#CA, 1:1, 16#FF:8, 0:23 , Rest/binary>>, _) ->
    {negative_infinity, Rest};
unpack_stream(<<16#CA, _:1, 16#FF:8, _:23 , Rest/binary>>, _) ->
    {nan, Rest};
unpack_stream(<<16#CB, V:64/float-unit:1, Rest/binary>>, _) ->
    {V, Rest};
unpack_stream(<<16#CB, 0:1, 2#11111111111:11, 0:52, Rest/binary>>, _) ->
    {positive_infinity, Rest};
unpack_stream(<<16#CB, 1:1, 2#11111111111:11, 0:52 , Rest/binary>>, _) ->
    {negative_infinity, Rest};
unpack_stream(<<16#CB, _:1, 2#11111111111:11, _:52 , Rest/binary>>, _) ->
    {nan, Rest};

%% Unsigned integers
unpack_stream(<<16#CC, V:8/unsigned-integer, Rest/binary>>, _) ->
    {V, Rest};
unpack_stream(<<16#CD, V:16/big-unsigned-integer-unit:1, Rest/binary>>, _) ->
    {V, Rest};
unpack_stream(<<16#CE, V:32/big-unsigned-integer-unit:1, Rest/binary>>, _) ->
    {V, Rest};
unpack_stream(<<16#CF, V:64/big-unsigned-integer-unit:1, Rest/binary>>, _) ->
    {V, Rest};

%% Signed integers
unpack_stream(<<16#D0, V:8/signed-integer, Rest/binary>>, _) ->
    {V, Rest};
unpack_stream(<<16#D1, V:16/big-signed-integer-unit:1, Rest/binary>>, _) ->
    {V, Rest};
unpack_stream(<<16#D2, V:32/big-signed-integer-unit:1, Rest/binary>>, _) ->
    {V, Rest};
unpack_stream(<<16#D3, V:64/big-signed-integer-unit:1, Rest/binary>>, _) ->
    {V, Rest};

%% Strings as new spec, or Raw bytes as old spec
unpack_stream(<<2#101:3, L:5, V:L/binary, Rest/binary>>, Opt) ->
    unpack_str_or_raw(V, Opt, Rest);

unpack_stream(<<16#D9, L:8/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>,
              ?OPTION{spec=new} = Opt) ->
    %% D9 is only for new spec
    unpack_str_or_raw(V, Opt, Rest);

unpack_stream(<<16#DA, L:16/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Opt) ->
    %% DA and DB, are string/binary
    unpack_str_or_raw(V, Opt, Rest);

unpack_stream(<<16#DB, L:32/big-unsigned-integer-unit:1, V:L/binary, Rest/binary>>, Opt) ->
    unpack_str_or_raw(V, Opt, Rest);

%% Arrays
unpack_stream(<<2#1001:4, L:4, Rest/binary>>, Opt) ->
    unpack_array(Rest, L, [], Opt);
unpack_stream(<<16#DC, L:16/big-unsigned-integer-unit:1, Rest/binary>>, Opt) ->
    unpack_array(Rest, L, [], Opt);
unpack_stream(<<16#DD, L:32/big-unsigned-integer-unit:1, Rest/binary>>, Opt) ->
    unpack_array(Rest, L, [], Opt);

%% Maps
unpack_stream(<<2#1000:4, L:4, Rest/binary>>, Opt) ->
    Unpacker = Opt?OPTION.map_unpack_fun,
    Unpacker(Rest, L, Opt);
unpack_stream(<<16#DE, L:16/big-unsigned-integer-unit:1, Rest/binary>>, Opt) ->
    Unpacker = Opt?OPTION.map_unpack_fun,
    Unpacker(Rest, L, Opt);

unpack_stream(<<16#DF, L:32/big-unsigned-integer-unit:1, Rest/binary>>, Opt) ->
    Unpacker = Opt?OPTION.map_unpack_fun,
    Unpacker(Rest, L, Opt);

%% Tag-encoded lengths (kept last, for speed)
%% positive int
unpack_stream(<<0:1, V:7, Rest/binary>>, _) -> {V, Rest};

%% negative int
unpack_stream(<<2#111:3, V:5, Rest/binary>>, _) -> {V - 2#100000, Rest};

%% Invalid data
unpack_stream(<<16#C1, _R/binary>>, _) ->  throw({badarg, 16#C1});

%% for extention types

%% fixext 1 stores an integer and a byte array whose length is 1 byte
unpack_stream(<<16#D4, T:1/signed-integer-unit:8, Data:1/binary, Rest/binary>>,
              ?OPTION{ext_unpacker=Unpack, original_list=Orig} = Opt) ->
    maybe_unpack_ext(16#D4, Unpack, T, Data, Rest, Orig, Opt);

%% fixext 2 stores an integer and a byte array whose length is 2 bytes
unpack_stream(<<16#D5, T:1/signed-integer-unit:8, Data:2/binary, Rest/binary>>,
              ?OPTION{ext_unpacker=Unpack, original_list=Orig} = Opt) ->
    maybe_unpack_ext(16#D5, Unpack, T, Data, Rest, Orig, Opt);

%% fixext 4 stores an integer and a byte array whose length is 4 bytes
unpack_stream(<<16#D6, T:1/signed-integer-unit:8, Data:4/binary, Rest/binary>>,
              ?OPTION{ext_unpacker=Unpack, original_list=Orig} = Opt) ->
    maybe_unpack_ext(16#D6, Unpack, T, Data, Rest, Orig, Opt);

%% fixext 8 stores an integer and a byte array whose length is 8 bytes
unpack_stream(<<16#D7, T:1/signed-integer-unit:8, Data:8/binary, Rest/binary>>,
              ?OPTION{ext_unpacker=Unpack, original_list=Orig} = Opt) ->
    maybe_unpack_ext(16#D7, Unpack, T, Data, Rest, Orig, Opt);

%% fixext 16 stores an integer and a byte array whose length is 16 bytes
unpack_stream(<<16#D8, T:1/signed-integer-unit:8, Data:16/binary, Rest/binary>>,
              ?OPTION{ext_unpacker=Unpack, original_list=Orig} = Opt) ->
    maybe_unpack_ext(16#D8, Unpack, T, Data, Rest, Orig, Opt);

%% ext 8 stores an integer and a byte array whose length is upto (2^8)-1 bytes:
unpack_stream(<<16#C7, Len:8, Type:1/signed-integer-unit:8, Data:Len/binary, Rest/binary>>,
              ?OPTION{ext_unpacker=Unpack, original_list=Orig} = Opt) ->
    maybe_unpack_ext(16#C7, Unpack, Type, Data, Rest, Orig, Opt);

%% ext 16 stores an integer and a byte array whose length is upto (2^16)-1 bytes:
unpack_stream(<<16#C8, Len:16, Type:1/signed-integer-unit:8, Data:Len/binary, Rest/binary>>,
              ?OPTION{ext_unpacker=Unpack, original_list=Orig} = Opt) ->
    maybe_unpack_ext(16#C8, Unpack, Type, Data, Rest, Orig, Opt);

%% ext 32 stores an integer and a byte array whose length is upto (2^32)-1 bytes:
unpack_stream(<<16#C9, Len:32, Type:1/signed-integer-unit:8, Data:Len/binary, Rest/binary>>,
              ?OPTION{ext_unpacker=Unpack, original_list=Orig} = Opt)  ->
    maybe_unpack_ext(16#C9, Unpack, Type, Data, Rest, Orig, Opt);

unpack_stream(_Bin, _Opt) ->
    throw(incomplete).

-spec unpack_array(binary(), non_neg_integer(), [msgpack:object()], ?OPTION{}) ->
                          {[msgpack:object()], binary()} | no_return().
unpack_array(Bin, 0,   Acc, _) ->
    {lists:reverse(Acc), Bin};
unpack_array(Bin, Len, Acc, Opt) ->
    {Term, Rest} = unpack_stream(Bin, Opt),
    unpack_array(Rest, Len-1, [Term|Acc], Opt).

map_unpacker(map) ->
    fun ?MODULE:unpack_map/3;
map_unpacker(jiffy) ->
    fun ?MODULE:unpack_map_jiffy/3;
map_unpacker(jsx) ->
    fun ?MODULE:unpack_map_jsx/3.

-spec unpack_map(binary(), non_neg_integer(), ?OPTION{}) ->
                        {map(), binary()} | no_return().
unpack_map(Bin, Len, Opt) ->
    unpack_map(Bin, Len, #{}, Opt).

unpack_map(Bin, 0, Acc, _) ->
    {Acc, Bin};
unpack_map(Bin, Len, Acc, Opt) ->
    {Key, Rest} = unpack_stream(Bin, Opt),
    {Value, Rest2} = unpack_stream(Rest, Opt),
    unpack_map(Rest2, Len-1, maps:put(Key, Value, Acc), Opt).

%% Users SHOULD NOT send too long list: this uses lists:reverse/1
-spec unpack_map_jiffy(binary(), non_neg_integer(), ?OPTION{}) ->
                              {msgpack:msgpack_map_jiffy(), binary()} | no_return().
unpack_map_jiffy(Bin, Len, Opt) ->
    {Map, Rest} = unpack_map_as_proplist(Bin, Len, [], Opt),
    {{Map}, Rest}.

-spec unpack_map_jsx(binary(), non_neg_integer(), ?OPTION{}) ->
                            {msgpack:msgpack_map_jsx(), binary()} | no_return().
unpack_map_jsx(Bin, Len, Opt) ->
    case unpack_map_as_proplist(Bin, Len, [], Opt) of
        {[], Rest} -> {[{}], Rest};
        {Map, Rest} -> {Map, Rest}
    end.

-spec unpack_map_as_proplist(binary(), non_neg_integer(), proplists:proplist(), ?OPTION{}) ->
                                    {proplists:proplist(), binary()} | no_return().
unpack_map_as_proplist(Bin, 0, Acc, _) ->
    {lists:reverse(Acc), Bin};
unpack_map_as_proplist(Bin, Len, Acc, Opt) ->
    {Key, Rest} = unpack_stream(Bin, Opt),
    {Value, Rest2} = unpack_stream(Rest, Opt),
    unpack_map_as_proplist(Rest2, Len-1, [{Key,Value}|Acc], Opt).

unpack_str_or_raw(V, ?OPTION{spec=old} = Opt, Rest) ->
    {maybe_bin(V, Opt), Rest};
unpack_str_or_raw(V, ?OPTION{spec=new,
                             unpack_str=UnpackStr,
                             validate_string=ValidateString} = Opt, Rest) ->
    {case UnpackStr of
         as_binary when ValidateString -> unpack_str(V), maybe_bin(V, Opt);
         as_binary -> maybe_bin(V, Opt);
         as_list -> unpack_str(V);
         as_tagged_list -> {string, unpack_str(V)}
     end, Rest}.

maybe_bin(Bin, ?OPTION{known_atoms=Known}) when Known=/=[] ->
    case lists:member(Bin,Known) of
        true ->
            erlang:binary_to_existing_atom(Bin,utf8);
        false ->
            Bin
    end;

maybe_bin(Bin, _) ->
    Bin.

%% NOTE: msgpack DOES validate the binary as valid unicode string.
unpack_str(Binary) ->
    case unicode:characters_to_list(Binary) of
        {error, _S, _Rest} -> throw({invalid_string, Binary});
        {incomplete, _S, _Rest} -> throw({invalid_string, Binary});
        String -> String
    end.

maybe_unpack_ext(F, _, _, _, _Rest, _, ?OPTION{spec=old}) ->
    %% trying to unpack new ext formats with old unpacker
    throw({badarg, {new_spec, F}});
maybe_unpack_ext(F, undefined, _, _, _Rest, _, _) ->
    throw({badarg, {bad_ext, F}});
maybe_unpack_ext(_, Unpack, Type, Data, Rest, Orig, _)
  when is_function(Unpack, 3) ->
    case Unpack(Type, Data, Orig) of
        {ok, Term} -> {Term, Rest};
        {error, E} -> {error, E}
    end;
maybe_unpack_ext(_, Unpack, Type, Data, Rest, _, _)
  when is_function(Unpack, 2) ->
    case Unpack(Type, Data) of
        {ok, Term} -> {Term, Rest};
        {error, E} -> {error, E}
    end.

