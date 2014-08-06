%%
%% Copyright (C) 2010-2014 by krasnop@bellsouth.net (Alexei Krasnopolski)
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License. 
%%

%% @since 2011-03-31
%% @copyright 2010-2014 Alexei Krasnopolski
%% @author Alexei Krasnopolski <krasnop@bellsouth.net> [http://krasnopolski.org/]
%% @version {@version}
%% @doc The module represents an example of using of erlang client. Function run/0
%% initiates an execution of 3 processes named 'producer', 'consumer' and 'cleaner'. First process
%% generates and inserts to database a messages, second one retrives and processes the messages and 
%% third process deletes processed messages from database. The processes are running concurrently
%% and are using separate connection to database. Fourth process is watcher that is periodicaly asking
%% database for count of processed messages. If database is empty the task is completed. 
%%
%%
-module(example).

%%
%% Include files
%%
-include("client_records.hrl").
-include("mysql_types.hrl").
-include("test.hrl").

%%
%% Import modules
%%

%%
%% Exported Functions
%%
-export([run/0, run_producer/1, run_consumer/0, run_watcher/1, run_cleaner/0,
				create_schema/0, insert_message/4, get_messages_list/1,
				process_entry/1, delete_message/1, watcher/3, 
				get_count_messages/1]).

%%
%% API Functions
%%

%% @spec run() -> any()
%% @doc Starting point for example application. The function creates 2 tables in database and spawns 3 processes: producer, consumer and
%% cleaner. Then it begins to wait for 'start_watch' message. After the message is received
%% watcher process is started and main process goes to wait for 'stop' message.
%% 'start_watch' message is generated by producer after last message has inserted to database.
%% 'stop' message is generated by watcher after database returns to empty state.
%%
run() ->
	my:start_client(),
	DS_def = #datasource{
		host = ?TEST_SERVER_HOST_NAME, 
		port = ?TEST_SERVER_PORT, 
		database = ?TEST_DB_NAME, 
		user = ?TEST_USER, 
		password = ?TEST_PASSWORD, 
%    flags = #client_options{}
    flags = #client_options{trans_isolation_level = serializable}
	},
	my:new_datasource(datasource, DS_def),

	create_schema(),
	Self = self(),
	spawn(fun() -> run_producer(Self) end),
	Cons_pid = spawn(fun run_consumer/0),
	Clean_pid = spawn(fun run_cleaner/0),
	receive
		start_watch -> ok
	end,
	spawn(fun() -> run_watcher(Self) end),
	receive
		stop -> 
			Cons_pid ! stop,
			Clean_pid ! stop,
			timer:sleep(1000),
			my:stop_client()
	end
.

%% @spec run_producer(P_pid::pid()) -> any() 
%% @doc The function inserts some amount of messages to database. And then it sends a message
%% 'start_watch' to parent (main) process.
%%
run_producer(P_pid) ->
	Conn = get_connection(),
	insert_message(Conn, 0, 100, 0),
	insert_message(Conn, 1000, 100, 10),
	datasource:return_connection(datasource, Conn),
	P_pid ! start_watch
.

%% @spec run_consumer() -> any()
%% @doc The function starts concurrent_runner for process entry operations and
%% waiting for stop message. Each 100 milisecond concurrent_runner is restarted.
%%
run_consumer() ->
	concurrent_runner("not", fun process_entry/1),
	receive
		stop -> ?debug_Fmt(" !!! Stop consumer", [])
	after 100 -> run_consumer()
	end
.

%% @spec run_cleaner() -> any()
%% @doc The function starts concurrent_runner for delete entry operations and
%% waiting for stop message. Each 100 milisecond concurrent_runner is restarted.
%%
run_cleaner() ->
	concurrent_runner("done", fun delete_message/1),
	receive
		stop -> ?debug_Fmt(" !!! Stop cleaner", [])
	after 100 -> run_cleaner()
	end
.

%% @spec run_watcher(P_pid::pid()) -> any()
%% @doc The function establishes connection to database and recursively retreives
%% count of messages in the database. If database is empty then completes execution.
%%
run_watcher(P_pid) ->
	Conn = get_connection(),
	watcher(Conn, P_pid, 0),
	datasource:return_connection(datasource, Conn)
.

%%
%% Local Functions
%%

%% @spec create_schema() -> any() 
%% @doc Create two tables: 'message' and 'property'. 'Message' has one-to-many relationship to
%% 'property' table.
%%
%% <img src="example-erlMySQL.png"/>
%%
%%
create_schema() ->
 	Conn = datasource:get_connection(datasource),
	{_,[_Ok]} = connection:execute_query(Conn, "CREATE DATABASE IF NOT EXISTS eunitdb"),
	Query1 = ["CREATE TABLE IF NOT EXISTS `message` (",
	" `id` bigint(20) NOT NULL AUTO_INCREMENT,",
	" `version` bigint(20) unsigned zerofill NOT NULL DEFAULT '0',",
	" `header` varchar(100) NOT NULL,",
	" `body` blob NOT NULL,",
	" `processed` enum('not','active','done') NOT NULL DEFAULT 'not',",
	" `producer_id` bigint(20) DEFAULT NULL,",
	" `update_time` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,",
	" PRIMARY KEY (`id`),",
	" KEY `processed` (`processed`)",
  " ) ENGINE=InnoDB DEFAULT CHARSET=utf8;"],
	{_,[_Ok1]} = connection:execute_query(Conn, Query1),

	Query2 = ["CREATE TABLE IF NOT EXISTS `property` (",
	" `id` bigint(20) NOT NULL AUTO_INCREMENT,",
	" `message_id` bigint(20) NOT NULL,",
	" `key` varchar(100) DEFAULT NULL,",
	" `value` varchar(100) DEFAULT NULL,",
	" PRIMARY KEY (`id`),",
	" KEY `message` (`message_id`),",
	" CONSTRAINT `message` FOREIGN KEY (`message_id`) REFERENCES `message` (`id`)",
	" ON DELETE NO ACTION ON UPDATE NO ACTION",
	" ) ENGINE=InnoDB DEFAULT CHARSET=utf8;"],
	{_,[_Ok2]} = connection:execute_query(Conn, Query2),
	datasource:return_connection(datasource, Conn)
.

%% @spec insert_message(Connection::#connection{}, N::integer(), M::integer(), SleepTime::integer()) -> any() 
%% @doc The function inserts to database one message entity and three property entities these belong to the message.
%%  N - number of message, M - amount of message to insert, SleepTime - delay between insert operations.
%%
insert_message(_, _, 0, _) -> stop;
insert_message(Conn, N, M, SleepTime) ->
	F = fun(C) ->
		N_string = integer_to_list(N),
		{_,[Ok]} = connection:execute_query(C, "INSERT INTO message VALUES (NULL,0,'header " ++ N_string ++ "','<body>Text</body>','not',1,NULL)"),
		Id = Ok#ok_packet.insert_id,
		Id_string = integer_to_list(Id),
		{_,[#ok_packet{}]} = connection:execute_query(C, "INSERT INTO property VALUES (NULL," ++ Id_string ++ ",'key #0','value #0')"),
		{_,[#ok_packet{}]} = connection:execute_query(C, "INSERT INTO property VALUES (NULL," ++ Id_string ++ ",'key #1','value #1')"),
		{_,[#ok_packet{}]} = connection:execute_query(C, "INSERT INTO property VALUES (NULL," ++ Id_string ++ ",'key #2','value #2')"),
		?debug_Fmt(" =>= Insert message #~p [id=~p]", [N,Id]) 
	end,
	connection:transaction(Conn, F),
	timer:sleep(SleepTime),
	insert_message(Conn, N+1, M-1, SleepTime)
.

%% @spec concurrent_runner(Mark::string(), Process::fun()) -> any()
%% @doc The function retrives list of Ids from DB. If Mark == 'not' the entries
%% will be processed, if Mark == 'done' the entries will be deleted.
%% Then for each id from list separate process is created to execute Process
%% operation. After that it is waiting for all executions are completed.
%%
concurrent_runner(Mark, Process) ->
	List_ids = get_messages_list(Mark),
	Op = case Mark of
		"done" -> "delete";
		"not" -> "process"
	end,
	?debug_Fmt("List ids to ~s : [~s]", [Op, for_print_Ids(List_ids)]),
	Self = self(),
	F = fun(Id) ->
		spawn(fun() ->
			Process(Id),
			Self ! done 
		end)
	end,
	lists:map(F, List_ids),
	counter(length(List_ids))
.

%% @spec counter(N::integer()) -> any()
%% @doc The function is waiting for N 'done' messages arrived.
%%
counter(0) -> ok;
counter(N) ->
	receive
		done -> counter(N - 1)
	end
.

%% @spec get_messages_list(Processed::integer()) -> any()
%% @doc Retrieves a list of ids of messages marked processed or unprocessed. 
%% The list size is limited to 10.
%%
get_messages_list(Processed) ->
%	?debug_Fmt(" --> get_messages_list(~p)", [Processed]),
	F = fun(C) ->
		{_,Ids} = connection:execute_query(C, "SELECT id FROM message WHERE processed = '" 
					++ Processed ++ "' LIMIT 10"),
		lists:map(fun([Id]) -> Id end, Ids)
	end,
	Conn = get_connection(),
	L =
	try
		connection:transaction(Conn, F)
	catch
		_:Why -> ?debug_Fmt(" **** Exception = ~p;", [Why]), 0
	end,
	datasource:return_connection(datasource, Conn),
%	?debug_Fmt(" <-- get_messages_list(~p) ; ~p", [Processed, length(L)]),
	L
.

%% @spec process_entry(Id::integer()) -> any()
%% @doc Marks message with Id as processed.
%%
process_entry(Id) ->
%	?debug_Fmt(" =>= Process message [id=~p]", [Id]),
	Conn = get_connection(),
	Handle = connection:get_prepared_statement_handle(Conn,
				"UPDATE message SET processed=? WHERE id=?"),
	try
		connection:transaction(Conn, fun(C) ->
			{_,[#ok_packet{}]} = connection:execute_statement(C, Handle, [?VARCHAR,?LONGLONG], ["active",Id]),
      timer:sleep(750),
      {_,[#ok_packet{}]} = connection:execute_statement(C, Handle, [?VARCHAR,?LONGLONG], ["done",Id])
		end),
    ?debug_Fmt(" =<= Message [id=~p] was processed", [Id]) 
	catch
		_:Why -> ?debug_Fmt(" **** Exception = ~p;", [Why])
	end,
	connection:close_statement(Conn, Handle),
	datasource:return_connection(datasource, Conn)
.

%% @spec delete_message(Id::integer()) -> any() 
%% @doc Deletes message with Id and correspondend property rows.
%%
delete_message(Id) ->
%	?debug_Fmt(" >>> delete_message(Conn, ~p)", [Id]), 
	Conn = get_connection(),
	F = fun(C) ->
		{_,[#ok_packet{}]} = connection:execute_query(C, "DELETE FROM property WHERE message_id=" ++ integer_to_list(Id)),
		{_,[#ok_packet{}]} = connection:execute_query(C, "DELETE FROM message WHERE id=" ++ integer_to_list(Id))
	end,
	try
		connection:transaction(Conn, F),
    ?debug_Fmt(" =X= Entry [id=~p] was deleted", [Id]) 
	catch
		_:Why -> ?debug_Fmt(" **** Exception = ~p;", [Why])
	end,
	datasource:return_connection(datasource, Conn)
.

%% @spec watcher(Connection::pid(), P_pid::pid(), N::integer()) -> any()
%% @doc Recursively queries message table for count of rows. If the table becomes empty
%% the function sends 'stop' to parent process.
%%
watcher(Conn, P_pid, N) ->
	timer:sleep(1000),
	{_,[Row]} = get_count_messages(Conn),
	[Count] = Row,
	?debug_Fmt("Count = ~p", [Count]),
	case Count of
		0 -> P_pid ! stop;
		_ when Count =:= N -> P_pid ! stop;
		_ -> watcher(Conn, P_pid, Count)
	end
.

%% @spec get_count_messages(Connection::pid()) -> any()
%% @doc Gets count of rows in message table.
%%
get_count_messages(Conn) ->
	F = fun(C) ->
		connection:execute_query(C, "SELECT count(*) FROM message")
	end,
	connection:transaction(Conn, F)
.

get_connection() ->
	Conn = datasource:get_connection(datasource),
%	my:execute_query(Conn,"SET SESSION TRANSACTION ISOLATION LEVEL SERIALIZABLE"),
	Conn
.

%% @spec for_print_Ids(L::list(integer())) -> string() 
%% 
%% @doc Helper function for printing.
%%
for_print_Ids(L) -> for_print_Ids(L, []).
for_print_Ids([], Str) -> Str ++ "";
for_print_Ids([Id | []], Str) -> Str ++ integer_to_list(Id);
for_print_Ids([Id | RL], Str) ->  for_print_Ids(RL, Str ++ integer_to_list(Id) ++ ",").
