#!/usr/bin/env lua

--[[

Copyright © 2015 Mihail Zuev <z.m.c@list.ru>. 
Author: Mihail Zuev <z.m.c@list.ru>.
 
All rights reserved.
 
Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the <organization> nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.
                                                                                
THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL <COPYRIGHT HOLDER> BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

--]]

-- Extensions Library(try/switch/setfenv/clonefup and more)
require "extens"

-- Logging Library
local log = require "log"

-- Standart LUA Socket Library
local socket = require "socket"

-- UUID library that allow to generate unique id
local uuid = require "uuid"

-- Event Library
local ev = require "ev"

-- A library that implements the minimum functionality of Asterisk Manager Interface
local AMI = require "roles.AMI"

-- A library that implements the minimum functionality of Asterisk Gateway Interface
local AGI = require "roles.AGI"

-- Define prototypes of future functions 
local event_occurred, ping

-- Future Objects Respectively
local ami, agi

-- Table that contains startup options
local conf = {}

-- User defined AGI/AMI area
local harea

-- Secure call function, implementation of which depends on lua version
local eval


-- If loose AMI connection, loop of ping with 5 seconds interval
-- Until the connection will not be restored 
function ping(loop,obj)
	log.warn(string.format("Try connect to %s:%s",ami.host,ami.port))

	-- Make connection on the socket
	-- If connection is succesfull then login
	if ami:get_connection() then
		local stat, err = ami:login(ami.conf['user'],ami.conf['secret'])

		-- If login fail, just return from function
		if not stat then
			return
		end

		-- Login is succesfull then run event listener for AMI flow
		if ami['socket'] then
			obj:stop(loop)
			io.new(event_occurred,ami.socket:getfd(),ev.READ):start(loop)
			log.info(string.format("Connect %s:%s is succesfull",ami.host,ami.port))
		end
	end
end

-- Async wait some event, some time or run when idle system
local function await(n)
	local thread, main = coroutine.running()

	-- We can run only inside coroutine
	if not main then
		-- Just non-blocking await some time
		if type(n) == 'number' then
			timer.new(function()
				coroutine.resume(thread)
			end,n):start(kernel)
		-- Non-blocking wait until function(as incoming parameter) return non-true
		elseif type(n) == "function" then
			local stat, err
			local w = 0.005
			-- Idle simulation with 5ms interval
			timer.new(function(l,i)
				if n(w) then
					i:stop(l)
					stat, err = coroutine.resume(thread)

					-- If an error ocurred inside coroutine
					-- Just print error message and move on
					-- This method uses in ypcall call
					if not stat then
						log.error(err)
					end
				end
			end,w,w):start(kernel)
		else -- Finally wait until system not idle
			idle.new(function(l,i)
				i:stop(l)
				coroutine.resume(thread)
			end):start(kernel)
		end
		return coroutine.yield()
	else
		log.warn("run only inside coroutine")
	end
end

-- This function is needed only if we use lua version 5.1 or older
-- This is allow secure call (aka 'pcall') and 'yield' from it
local function ypcall(...)
	await((function(f,...)
		-- Create coroutine for user-defined script
		local co = coroutine.create(f)

		if co then
			-- Start user-defined script like a coroutine
			-- Subsequently, if user allowed error inside his script
			-- 'await' just print error message and move on
			local stat, err = coroutine.resume(co,...)

			-- Checking for possible errors
			if not stat then
				-- Just print error message and move on
				log.error(err)
			end

			-- Closure that will be monitor the state of the coroutine 
			return function()
				if coroutine.status(co) == 'dead' then
					return true
				end
			end
		end
	end)(...))
end

-- Translation functions by key into AMI command
local function mngr(self, key)
	-- Create closure
	-- That allow to remember current AMI session at runtime
	return function(args)
		-- Table that will be returned as an response
		local t = {}
		-- Local copy of AMI object
		local ami = ami
		-- Unique ID that acts as ActionID
		local uniqid = uuid.new()
		local param = {
			actionid = uniqid
		}

		-- Prepare(lower key) parameters for AMI command
		-- Ignore ActionID, use self-generated
		if type(args) == "table" then
			for k,v in pairs(args) do
				if not param[string.lower(k)] then 
					param[string.lower(k)] = v
				end
			end
		end

		await((function(time)
			-- watchdog timer
			local step = 0
			-- Determine how much time should elapse
			local when = type(time) == "number" and time or 0.200

			-- Execute AMI command
			ami:command(key,param)

			-- Another closure that await response
			return function(n)
				-- Increment watchdog timer
				step = step + n

				-- Check response by ActionID
				if ami.responses[uniqid] then
					return true
				end

				-- Stop wait if elapsed watchdog timer but response not received
				if step > when then return true end
			end
		end)())

		-- If await returned by receive response
		if ami.responses[uniqid] then
			-- Extract response by ActionID previously generated
			-- Then delete the response from global AMI object
			t,ami.responses[uniqid] = ami.responses[uniqid],nil
		end

		return t
	end
end

-- Translation functions by key in the dialplan application or get some data from current channel
local function channel(self, key)
	-- Flag that indicate what we want, run dialplan application(false) or get some data from channel(true)
	local getter = false
	-- Just in case to distinguish some actions
	local act = switch(key,true) {
		['get'] = function(k)
			getter = true
			return 'get variable'
		end,
		['default'] = function(k)
			return table.concat({'exec',k},' ')
		end
	}

	-- Create closure
	-- That allow to remember current AGI session at runtime
	return function(...)
		local args = {}
		local sess = self.agi

		for i = 1,select('#',...) do
			local v = select(i,...)
			table.insert(args,'"' .. (v and tostring(v) or '') .. '"')
		end

		await((function()
				sess:execute(table.concat({act,table.concat(args,',')},' '))
				-- Another closure that run required application and await response
				return function()
					if sess['status'] and sess['result'] then
						return true
					end
				end
		end)())

		-- If requested getter then return data that we have
		return getter and sess['data'] or sess['status']
	end
end

-- Function that allow to load AMI/AGI handlers to some table space
local function load_area(fn,...)
	-- Allow call AMI commands from manager.command syntax
	-- And proxy some methods of the AMI object
	local area = {
		log = log,
		await = await,
		ypcall = ypcall,
		ami = setmetatable({
			addEvent = function(...)
				return ami:addEvent(...)
			end,
			addEvents = function(...)
				ami:addEvents(...)
			end,
			removeEvent = function(...)
				return ami:removeEvent(...)
			end,
			removeEvents = function(...)
				ami:removeEvents(...)
			end,
			listEvents = function()
				return ami['events']
			end
		},{__index = mngr})
	}

	-- Create a coroutine that allows us to use manager.command at the time of loading the area
	if type(fn) == "function" then
		local stat, err = coroutine.resume(
			coroutine.create(
				function()
					eval(setfenv(fn,setmetatable(area,{__index = _G})))
				end
			)
		)

		-- Checking for possible errors
		if not stat then
			-- Just print error message and move on
			log.error(err)
		end
	else
		-- If user allowed error inside area
		-- Just print error message and move on
		log.error(...)
	end

	return area
end

-- Parse command line options
local function optargs(...)
	-- Marker of current option
	local mark
	-- Table who will contain all parsed options
	local opts = {}

	-- Loop all options
	for _, chars in ipairs({...}) do
		-- Find -o or --option syntax
		if string.match(chars,'^%-.+') then
			-- Set marker and the same key in the opts table
			mark = (function(v) local v = v or 0 opts[v] = true return v end)(string.match(chars, '^-+(.+)$'))
		else
			-- If chars is not option
			-- Then set value in the opts table with the same key as marker
			if mark then
				opts[mark], mark = chars or '', nil -- And reset marker
			else
				table.insert(opts,chars) -- Collect all other garbage
			end
		end
	end

	return opts
end

-- Function that load appropriate config
local function config(cf)
	-- Default values
	local conf = {
		role = 'both',
		user = 'manager',
		secret = 'password',
		listen = '*',
		host = '127.0.0.1',
	}
	
	if cf then
		-- Load config file
		local config_init = loadfile(cf)

		if type(config_init) == 'function' then
			local env = {} -- Future environment
			
			-- Load Config content to appropriate environment
			setfenv(config_init,env)()

			-- Merge default conf table and table just loaded
			for k,v in pairs(env) do conf[string.lower(k)] = v end
		end
	end

	return conf
end

-- Function that Initialize all necessary at startup
local function init(...)
	local err = {}
	-- Parse command line parameters
	local opts = optargs(...)
	-- Configure like in config file
	conf = config(opts['c'] or opts['conf'] or opts['config'])

	-- Prepare log object
	log.file = conf['log'] or log.file
	log.level = conf['level'] or log.level
	log.ident = conf['ident'] or log.ident

	-- Firstly fill environments
	if ev then
		for k,v in pairs({
			idle = ev.Idle,
			timer = ev.Timer,
			signal = ev.Signal,
			kernel = ev.Loop.default,
			io = setmetatable(io,{__index = ev.IO})
		}) do _G[k] = v	end
	else
		error("Event-driven Library is not loaded")
	end

	-- Secondly prepare the future secure call function
	eval = ((string.match(string.lower(_VERSION),'lua 5.(%d)') + 0) > 1 or type(jit) == 'table')
	and function(...)
		-- try secure call
		local stat, err = pcall(...)

		-- If user allowed error inside secure call 
		-- just print error message and move on
		if not stat then
			log.error(err)
		end
	end
	or ypcall

	-- Thirdly create FastAGI socket listener if role allowed
	if string.match(string.lower(conf['role']),'agi') or string.match(string.lower(conf['role']),'both') then
		agi, err[1] = socket.bind(
			string.match(conf['listen'],'[^:]+'),
			tonumber(string.match(conf['listen'],':(%d*)')) or 4573
		)
	end

	-- Fourthly connect to Asterisk Manager Interface if role allowed
	if string.match(string.lower(conf['role']),'ami') or string.match(string.lower(conf['role']),'both') then
		ami, err[2] = AMI{
			host = string.match(conf['host'],'[^:]+'),
			port = tonumber(string.match(conf['host'],':(%d*)')) or 5038,
			user = conf['user'],
			secret = conf['secret'],
			timeout = 0.005,
			logger = function(...) log.warn(...) end
		}
	end

	if (string.match(string.lower(conf['role']),'agi') or string.match(string.lower(conf['role']),'both')) and not agi then
		error(err[1])
	end

	if (string.match(string.lower(conf['role']),'ami') or string.match(string.lower(conf['role']),'both')) and not ami['socket'] then
		log.warn(err[2])
		log.warn('Will try again after 5 seconds')

		-- Start pinger
		timer.new(ping,5.0,5.0):start(kernel)
	end

	-- Load AGI/AMI area
	harea = load_area(loadfile(conf['handler']))

end

-- Parse event flow from AMI
local parse_events = function()
	-- local copy of AMI socket connection
	local sock = ami.socket
	-- Flag that indicates that the current flow is response on the command action
	local cmd

	-- Table that contents Event object by key/value
  local t = {}

	-- Table that contents ordered list of all incoming events
	local buff = {}

  while true do
    local line, err = sock:receive()

		if not line then
			if err ~= "timeout" then
				return nil, err
			else
				return buff
			end
    end

		-- This Flow is Command
		-- Set appropriate flag
		if (line:match("^Privilege%s*:%s*Command")) or (line:match("^Response%s*:%s*Follows")) then
			cmd = true
		end

		-- Catch END of Command Action
		if cmd and (line:match("END COMMAND")) then cmd = false end

		-- Check empty line
    if #line == 0 then
			-- If not set Command Action Flag
			-- Then it is simple event flow
			if not cmd then
				buff[#buff + 1] = t
				t = {}
			end
		else
			-- Parse incoming line
			local k, v = line:match("^([%w%-]+)%s*:%s*(.*)$")

			-- If incoming line apart of Command Action
			-- Then just append it to 'Content' key
			if not k and cmd then
				k,v = 'Content',line or ""
			end

			if t[k] and cmd then
				if type(t[k]) ~= "table" then
					t[k] = { t[k] }
				end
				t[k][#t[k] + 1] = v
			else
				if k then t[k] = v end
			end
    end
  end
end

-- Handle all new event flow
function event_occurred(loop,obj)
	-- Parse event flow
	local events, err = parse_events()

	-- Check the parsing
	if type(events) == "table" then
		-- Split events flow and responses
		for i,e in pairs(events) do
			for k,v in pairs(e) do
				local key = string.lower(k)

				if key == "actionid" then
					if ami.responses[v] then
						table.insert(ami.responses[v],e)
					else
						ami.responses[v] = { e }
					end

					-- Delete response from events list
					events[i] = nil

					-- Stop looping event keys, we are found everything all need
					break
				end
			end
		end

		-- Move next only if AMI area is exists
		if type(harea) == "table" then
			for _,event in pairs(events) do
				local e = type(event) == 'table' and string.lower(event['Event'])

				if e then
					local els = {}

					e = ami.events[e]
						and e
						or 'default'

					els = type(ami.events[e]) == 'table' and ami.events[e] or {ami.events[e]}

					for _,func in pairs(els) do
						-- Local copy of event
						local event = event
						-- Local copy of user-defined script
						local script = func

						-- Create coroutine who will work as event handler
						local stat, err = coroutine.resume(
							coroutine.create(
								function()
									eval(script,event)
								end
							)
						)

						-- Checking for possible errors
						if not stat then
							-- Just print error message and move on
							log.error(err)
						end
					end
				else
					log.warn("Malformed Event")
					log.debug(dumper(event))
				end
			end
		else
			-- Not exist AMI area or it's not table
			-- Just dump events flow
			for _,event in ipairs(events) do
				log.debug(dumper(event))
			end
		end
	else
		-- If connection closed for any reason
		-- Then run pinger with five second interval
		if err == 'closed' then 
			log.warn('We are got read error (socket closed)')
			log.warn('Will try again after 5 seconds')

			-- Stop AMI event-driven listener
			obj:stop(loop)
			-- AMI disconect, just in case
			ami.socket = ami:close() and nil
			-- Start pinger
			timer.new(ping,5.0,5.0):start(loop)
		else -- All other error on the socket
			-- Just print error message
			log.warn(err)
		end
	end
end

-- Process every new AGI connection
local sessions_request = function(...)
	local sock = ...
	-- Read and parse headers for new connection
	-- Create then AGI object
	local session, err = AGI {
		sock = sock,
		logger = function(...)
			log.warn(...)
		end
	}

	if session then
		session['params'] = {}
		
		-- parse scriptname from headers
		local scriptname = string.match(session.headers['network_script'] or '','^([^%?]*)')

		-- parse input params from uri
		for key,val in string.gmatch(session.headers['network_script'] or '','([^%?%=%&]+)=([^%=%&]*)') do
			session['params'][key] = val
		end	

		-- Move next only if user defined scriptname exist inside AGI area
		if type(harea) == "table" and type(harea[scriptname]) == "function" then
			-- Pre-define new event-driven listener(coroutine)
			local thread
			-- Local copy of user-defined script
			local script = harea[scriptname]
			-- Create new event-driven listener to process all incoming data
			local obj = io.new(function(loop,obj)
				-- Check coroutine state if not dead resume coroutine
				-- Else stop event-driven listener
				if coroutine.status(thread) ~= "dead" then
					coroutine.resume(thread)
				else
					obj:stop(loop)
				end
			end,sock:getfd(),ev.READ)

			thread = coroutine.create(function()
				-- Once at start we duplicate a coroutine thread as a local variable
				local thread = coroutine.running()

				while true do
					-- Extract incoming data
					local responses, err = session:response()

					if not responses then
						-- Destroy event-driven listener and exit from coroutine if any socket error
						return obj:stop(kernel)
					else
						for _,response in ipairs(responses) do
							-- Parse every part of incoming data
							if not session:checkresult(response) then
								-- Incoming data is request, because not AGI syntax response
								session.status = "event"
								session.data = response
							end

							if thread then
								-- await returned true if has request to stop coroutine
								-- then exit of coroutine
								if await() then return end
							end
						end
					end
					-- Will be returned true if has request to stop coroutine
					if coroutine.yield() then return end
				end
			end)

			-- Start just created event-driven listener
			obj:start(kernel)

			-- Create coroutine who will work as user-defined script
			local stat, err = coroutine.resume(coroutine.create(
				function(...)
					-- Local copy of AGI session
					local session = ...
					-- Create channel environment for user-defined script
					local chan = setmetatable({agi = session},{__index = channel})

					-- Start user-defined script and pass him 'app/channel' objects respectively as arguments
					eval(
						script,
						chan,
						setmetatable(
							{
								get = function(...)
									return chan.get(...)
								end,
								set = function(...)
									local var = select(1,...)
									local expr = var and "="
									local val = var and  string.format('%s',select(2,...) or "")

									return chan.set(table.concat({var,expr,val}))
								end
							},
							{__index = session.headers}
						)
					)

					-- End of, stop/free all no needed any more object
					obj:stop(kernel)
					sock:close()
					coroutine.resume(thread,'stop')
				end
			),session)

			-- Checking for possible errors
			if not stat then
				-- Just print error message and move on
				log.error(err)
			end
		else -- Not exist scriptname inside AGI area
			-- Just close connection
			sock:close()
		end
	else -- Not valid AGI session
		-- Just close connection
		sock:close()
	end

	-- NOTE: just in case
	--	Do not close the socket in this place as it may be needed by the suspended coroutine
end

-- Initialize all necessary
init(...)

-- If valid AGI session and Role allowed
if agi then
	-- Set timeout on server(listen) socket
	agi:settimeout(0.005)

	-- Event-driven loop on AGI socket
	io.new(function(...)
		local sock, err = agi:accept()

		if sock then
			sock:settimeout(0.005)

			sessions_request(sock)
		else
			log.warn(err)
		end
	end,agi:getfd(),ev.READ):start(kernel)
end

-- If valid AMI session and Role allowed
if ami['socket'] then
	-- Event-driven loop on AMI socket
	io.new(event_occurred,ami.socket:getfd(),ev.READ):start(kernel)
end

-- Some signals handlers
for _,s in pairs({1,3}) do
	signal.new(function()
		log.info("Attempt to reload all HANDLERS ...")

		-- Load AGI/AMI areas
		harea = load_area(loadfile(conf['handler']))
	end,s):start(kernel)
end

-- Start Main event-driven loop
kernel:loop()
