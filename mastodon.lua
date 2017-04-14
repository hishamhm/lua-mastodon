
---
-- @module mastodon
-- Super basic but thorough and easy to use mastodon.social
-- api wrapper in python.
--
-- If anything is unclear, check the official API docs at
-- https://github.com/Gargron/mastodon/wiki/API

local mastodon = {}

local lfs = require("lfs")
local requests = require("requests")
local split = require("split")
local socket = require("socket")
local date = require("date")
local mimetypes = require("mimetypes")
local mimedb = mimetypes.copy()

local DEFAULT_BASE_URL = "https://mastodon.social"
local DEFAULT_TIMEOUT = 300

local function urlencode(s)
   return s and (s:gsub("%W", function (c)
      if c ~= " " then
         return ("%%%02x"):format(c:byte())
      else
         return "+"
      end
   end))
end

local function formencode(form)
   local result = {}
   if form[1] then -- Array of ordered { name, value }
      for _, field in ipairs(form) do
         table.insert(result, urlencode(field.name).."="..urlencode(field.value))
      end
   else -- Unordered map of name -> value
      for name, value in pairs(form) do
         table.insert(result, urlencode(name).."="..urlencode(value))
      end
   end
   return table.concat(result, "&")
end

---
-- Create a new app with given client_name and scopes (read, write, follow)
--
-- Specify redirect_uris if you want users to be redirected to a certain page after authenticating.
-- Specify to_file to persist your apps info to a file so you can use them in the constructor.
-- Specify api_base_url if you want to register an app on an instance different from the flagship one.
--
-- Presently, app registration is open by default, but this is not guaranteed to be the case for all
-- future mastodon instances or even the flagship instance in the future.
--
-- Returns client_id and client_secret.
--
-- @param options A table with the following fields:
-- client_name (mandatory),
-- scopes (default is {"read", "write", "follow"}),
-- redirect_uris (default is nil),
-- website (default is nil),
-- to_file (default is nil),
-- api_base_url (default is DEFAULT_BASE_URL),
-- request_timeout (default is DEFAULT_TIMEOUT)
-- @return two strings: client_id and client_secret
function mastodon.create_app(options)
   local client_name = options.client_name
   local scopes = options.scopes or {"read", "write", "follow"}
   local redirect_uris = options.redirect_uris
   local website = options.website
   local to_file = options.to_file
   local api_base_url = options.api_base_url or DEFAULT_BASE_URL
   local request_timeout = options.request_timeout or DEFAULT_TIMEOUT
   
   if not client_name then
      return nil, "Missing client name"
   end

   local request_data = {
      client_name = client_name,
      scopes = table.concat(scopes, " ")
   }

   request_data.redirect_uris = redirect_uris or 'urn:ietf:wg:oauth:2.0:oob'
   request_data.website = website
   
   request_data = formencode(request_data)

   local ok, response = pcall(requests.post, { url = api_base_url .. '/api/v1/apps', data = request_data, timeout = request_timeout })
   if not ok then
      return nil, "Could not complete request: " .. tostring(response)
   end
   local json_response, json_error = response.json()
   if not json_response then
      return nil, json_error
   end

   if json_response.error then
      return nil, json_response.error
   end
   
   if to_file then
      local secret_file = io.open(to_file, "w")
      secret_file:write(json_response.client_id .. "\n")
      secret_file:write(json_response.client_secret .. "\n")
      secret_file:close()
   end

   return json_response.client_id, json_response.client_secret
end

--- @class Mastodon
local Mastodon = {}

---
-- Create a new API wrapper instance based on the given client_secret and client_id. If you
-- give a client_id and it is not a file, you must also give a secret.
--
-- You can also specify an access_token, directly or as a file (as written by log_in).
--
-- lua-mastodon can try to respect rate limits in several ways, controlled by ratelimit_method.
-- "throw" makes functions return failure when the rate
-- limit is hit. "wait" mode will, once the limit is hit, wait and retry the request as soon
-- as the rate limit resets, until it succeeds. "pace" works like throw, but tries to wait in
-- between calls so that the limit is generally not hit (How hard it tries to not hit the rate
-- limit can be controlled by ratelimit_pacefactor). The default setting is "wait". Note that
-- even in "wait" and "pace" mode, requests can still fail due to network or other problems! Also
-- note that "pace" and "wait" are NOT thread safe.
--
-- Specify api_base_url if you wish to talk to an instance other than the flagship one.
-- If a file is given as client_id, read client ID and secret from that file.
--
-- By default, a timeout of 300 seconds is used for all requests. If you wish to change this,
-- pass the desired timeout (in seconds) as request_timeout.
function mastodon.new(options)
   local client_id = options.client_id
   local client_secret = options.client_secret
   local access_token = options.access_token
   local api_base_url = options.api_base_url or DEFAULT_BASE_URL
   local debug_requests = options.debug_requests or false
   local ratelimit_method = options.ratelimit_method or "wait"
   local ratelimit_pacefactor = options.ratelimit_pacefactor or 1.1
   local request_timeout = options.request_timeout or DEFAULT_TIMEOUT
   
   if not client_id then
      return nil, "Missing client id"
   end

   local self = {
      api_base_url = api_base_url,
      client_id = client_id,
      client_secret = client_secret,
      access_token = access_token,
      debug_requests = debug_requests,
      ratelimit_method = ratelimit_method,
      _token_expired = os.date("*t"),
      _refresh_token = nil,

      ratelimit_limit = 150,
      ratelimit_reset = os.time(),
      ratelimit_remaining = 150,
      ratelimit_lastcall = os.time(),
      ratelimit_pacefactor = ratelimit_pacefactor,

      request_timeout = request_timeout,
   }

   if not ({throw = true, wait = true, pace = true})[ratelimit_method] then
      return nil, "Invalid ratelimit method."
   end

   if lfs.attributes(client_id) then
      local secret_file, err = io.open(client_id, "r")
      if not secret_file then
         return nil, err
      end
      self.client_id = secret_file:read("*l")
      self.client_secret = secret_file:read("*l")
      secret_file:close()
   elseif not self.client_secret then
      return nil, "Specified client id directly, but did not supply secret"
   end

   if self.access_token and lfs.attributes(self.access_token) then
      local token_file, err = io.open(self.access_token, "r")
      if not token_file then
         return nil, err
      end
      self.access_token = token_file:read("*l")
      token_file:close()
   end

   return setmetatable(self, { __index = Mastodon })
end

function Mastodon:token_expired(seconds)
   if seconds then
      self._token_expired = os.time() + seconds
   else
      return self._token_expired < os.time()
   end
end

function Mastodon:refresh_token(value)
   if value then
      self._refresh_token = value
   else
      return self._refresh_token
   end
end

---
-- Returns the url that a client needs to request the grant from the server.
-- https://mastodon.social/oauth/authorize?client_id=XXX&response_type=code&redirect_uris=YYY&scope=read+write+follow
--
function Mastodon:auth_request_url(options)
   local client_id = options.client_id
   local redirect_uris = options.redirect_uris or "urn:ietf:wg:oauth:2.0:oob"
   local scopes = options.scopes or {"read", "write", "follow"}

   if not client_id then
      client_id = self.client_id
   else
      if lfs.attributes(client_id) then
         local secret_file, err = io.open(client_id, "r")
         if not secret_file then
            return nil, err
         end
         client_id = secret_file:read("*l")
         secret_file:close()
      end
   end
            
   local params = {
      client_id = client_id,
      response_type = "code",
      redirect_uri = redirect_uris,
      scope = table.concat(scopes, " "),
   }
   
   local formatted_params = urlencode(params)
   
   return self.api_base_url .. "/oauth/authorize?" .. formatted_params
end

local function generate_params(options, exclude)
   local out = {}
   local exclude_set = {}
   for _, key in ipairs(exclude) do
      exclude_set[key] = true
   end
   for k, v in pairs(options) do
      if not exclude_set[k] then
         if type(v) == "table" then
            out[k.."[]"] = v
         else
            out[k] = v
         end
      end
   end
   return out
end

local function str(t)
   if type(t) ~= "table" then
      return tostring(t)
   end
   local out = {"{"}
   for k,v in pairs(t) do
      table.insert(out, tostring(k))
      table.insert(out, " = ")
      table.insert(out, tostring(v))
      table.insert(out, ", ")
   end
   table.insert(out,"}")
   return table.concat(out)
end

local function datetime_to_epoch(dt)
   -- TODO test -- is this correct or inverted?
   return math.floor(date.diff(date(dt), date.epoch():toutc()):spanseconds())
end

local function go_to_sleep(time)
   if time > 0 then
      -- As a precaution, never sleep longer than 5 minutes
      time = math.min(time, 5 * 60)
      socket.sleep(time)
      return true
   end
   return false
end

--- Internal API request helper.
local function api_request(self, method, endpoint, params, files, do_ratelimiting)
   params = params or {}
   files = files or {}

   local headers = nil

   -- "pace" mode ratelimiting: Assume constant rate of requests, sleep a little less long than it
   -- would take to not hit the rate limit at that request rate.
   if do_ratelimiting and self.ratelimit_method == "pace" then
      local remaining_wait = 0
      if self.ratelimit_remaining == 0 then
         go_to_sleep(self.ratelimit_reset - os.time())
      else
         local time_waited = os.time() - self.ratelimit_lastcall
         local time_wait = self.ratelimit_reset - os.time() / self.ratelimit_remaining
         remaining_wait = time_wait - time_waited
      end
      if remaining_wait > 0 then
         go_to_sleep(remaining_wait / self.ratelimit_pacefactor)
      end
   end
   
   -- Generate request headers
   if self.access_token then
      headers = {
         ["Authorization"] = 'Bearer ' .. self.access_token
      }
   end
   
   if self.debug_requests then
      print('Mastodon: Request to endpoint "' .. endpoint .. '" using method "' .. method .. '".')
      print('Parameters: ' .. str(params))
      print('Headers: ' .. str(headers))
      print('Files: ' .. str(files))
   end

   -- Make request
   local request_complete = false
   local response
   while not request_complete do
      request_complete = true
      if not ({ GET = true, POST = true, DELETE = true })[method] then
         return nil, "Invalid method " .. tostring(method)
      end
      -- FIXME lua-requests does not support 'files' yet
      local ok, response_object = pcall(requests[method:lower()], { url = self.api_base_url .. endpoint, data = formencode(params), headers = headers, files = files, timeout = self.request_timeout })
      if not ok then
         return nil, "Could not complete request: " .. tostring(response_object)
      end
      if not response_object then
         return nil, "Illegal request."
      end
      
      -- Handle response
      if self.debug_requests then
         print('Mastodon: Response received with code ' .. str(response_object.status_code) .. '.')
         print('response headers: ' .. str(response_object.headers))
         print('Response text content: ' .. str(response_object.text))
      end
      
      if response_object.status_code == 404 then
         return nil, "Endpoint not found"
      end
      if response_object.status_code == 500 then
         return nil, "General API problem"
      end

      local json_err
      response, json_err = response_object.json()
      if not response then
         return nil, "Could not parse response as JSON, response code was "..str(response_object.status_code)..", bad json content was '"..str(response_object.content).."'"
      end
      
      -- Handle rate limiting
      if do_ratelimiting and response_object.headers["X-RateLimit-Remaining"] then
         self.ratelimit_remaining = tonumber(response_object.headers['X-RateLimit-Remaining'])
         self.ratelimit_limit = tonumber(response_object.headers['X-RateLimit-Limit'])
         
         local ratelimit_reset_datetime = date(response_object.headers['X-RateLimit-Reset'])
         if not ratelimit_reset_datetime then
            return nil, "Rate limit time calculations failed", "ratelimit"
         end
         -- Adjust server time to local clock
         local server_time_datetime = date(response_object.headers['Date'])
         local server_time = datetime_to_epoch(server_time_datetime)
         local server_time_diff = os.time() - server_time
         self.ratelimit_reset = self.ratelimit_reset + server_time_diff
         self.ratelimit_lastcall = os.time()
         
         if response.error and response.error == "Throttled" then
            if self.ratelimit_method == "throw" then
               return nil, "Hit rate limit.", "ratelimit"
            elseif self.ratelimit_method == "wait" or self.ratelimit_method == "pace" then
               if go_to_sleep(self.ratelimit_reset - os.time()) then
                  request_complete = false
               end
            end
         end
      end
   end
   return response
end
   
---
-- Docs: https://github.com/doorkeeper-gem/doorkeeper/wiki/Interacting-as-an-OAuth-client-with-Doorkeeper
-- 
-- Notes:
-- Your username is the e-mail you use to log in into mastodon.
-- 
-- Can persist access token to file, to be used in the constructor.
-- 
-- Supports refresh_token but Mastodon.social doesn't implement it at the moment.
-- 
-- Handles password, authorization_code, and refresh_token authentication.
-- 
-- Will throw a MastodonIllegalArgumentError if username / password
-- are wrong, scopes are not valid or granted scopes differ from requested.
-- 
-- @return access_token a string.
function Mastodon:log_in(options)
   options.redirect_uri = options.redirect_uri or "urn:ietf:wg:oauth:2.0:oob"
   options.scopes = options.scopes or {'read', 'write', 'follow'}

   local params
   if options.username and options.password then
      params = generate_params(options, {'scopes', 'to_file', 'code', 'refresh_token'})
      params.grant_type = "password"
   elseif options.code then
      params = generate_params(options, {'scopes', 'to_file', 'username', 'password', 'refresh_token'})
      params.grant_type = "authorization_code"
   elseif options.refresh_token then
      params = generate_params(options, {'scopes', 'to_file', 'username', 'password', 'code'})
      params.grant_type = "refresh_token"
   else
      return nil, "Invalid arguments given. username and password or code are required."
   end

   params.scope = table.concat(options.scopes, ' ')
   params.client_id = self.client_id
   params.client_secret = self.client_secret
   
   local response, err = api_request(self, "POST", '/oauth/token', params, false)
   if not response then
      if options.username or options.password then
         return nil, "Invalid user name, password, or redirect_uris: "..tostring(err)
      elseif options.code then
         return nil, "Invalid user name, password, or redirect_uris: "..tostring(err)
      else
         return nil, "Invalid request: "..tostring(err)
      end
   end
   self.access_token = response.access_token
   self.refresh_token = response.refresh_token
   self.token_expired = response.expires_in and math.floor(tonumber(response.expires_in))

   table.sort(options.scopes)
   local requested_scopes = table.concat(options.scopes, " ")
   local their_scopes = split.split(response["scope"], " ")
   table.sort(their_scopes)
   local received_scopes = table.concat(their_scopes, " ")
   
   if requested_scopes ~= received_scopes then
      return nil, 'Granted scopes "' .. received_scopes .. '" differ from requested scopes "' .. requested_scopes .. '".'
   end

   if options.to_file then
      local token_file, err = io.open(options.to_file, "w")
      if not token_file then
         return nil, err
      end
      token_file:write(response.access_token .. "\n")
      token_file:close()
   end

   return response.access_token
end

---
-- Fetch statuses, most recent ones first. Timeline can be home, mentions, local,
-- public, or tag/hashtag. See the following functions documentation for what those do.
-- 
-- The default timeline is the "home" timeline.
-- 
-- @return a table of toot tables.
function Mastodon:timeline(options)
   options.timeline = options.timeline or "home"

   if options.timeline == "local" then
      options.timeline = "public"
      options["local"] = true
   end
   
   local params = generate_params(options, {'timeline'})
   return api_request(self, 'GET', '/api/v1/timelines/' .. options.timeline, params)
end

function Mastodon:timeline_home(options)
   options.timeline = "home"
   return self:timeline(options)
end

function Mastodon:timeline_home(options)
   options.timeline = "mentions"
   return self:timeline(options)
end

function Mastodon:timeline_local(options)
   options.timeline = "local"
   return self:timeline(options)
end

function Mastodon:timeline_public(options)
   options.timeline = "public"
   return self:timeline(options)
end

function Mastodon:hashtag(hashtag, options)
   options.timeline = "tag/" .. tostring(hashtag)
   return self:timeline(options)
end

function Mastodon:status(id)
   return api_request(self, "GET", "/api/v1/statuses/" .. tostring(id))
end

function Mastodon:status_context(id)
   return api_request(self, "GET", "/api/v1/statuses/" .. tostring(id) .. "/context")
end

function Mastodon:status_reblogged_by(id)
   return api_request(self, "GET", "/api/v1/statuses/" .. tostring(id) .. "/reblogged_by")
end

function Mastodon:status_favourited_by(id)
   return api_request(self, "GET", "/api/v1/statuses/" .. tostring(id) .. "/favourited_by")
end
Mastodon.favorited_by = Mastodon.favourited_by

function Mastodon:notifications()
   return api_request(self, "GET", "/api/v1/notifications")
end

function Mastodon:account(id)
   return api_request(self, "GET", "/api/v1/accounts/"..tostring(id))
end

function Mastodon:verify_credentials()
   return api_request(self, "GET", "/api/v1/accounts/verify_credentials")
end

function Mastodon:account_statuses(id, options)
   local params = generate_params(options or {})
   return api_request(self, "GET", "/api/v1/accounts/" .. tostring(id) .. "/statuses", params)
end

function Mastodon:account_following(id)
   return api_request(self, "GET", "/api/v1/statuses/" .. tostring(id) .. "/following")
end

function Mastodon:account_followers(id)
   return api_request(self, "GET", "/api/v1/statuses/" .. tostring(id) .. "/followers")
end

function Mastodon:account_relationships(id)
   local params = generate_params({ id = id })
   return api_request(self, "GET", "/api/v1/accounts/relationships", params)
end

function Mastodon:account_search(query, options)
   options = options or {}
   options.q = query
   local params = generate_params(options)
   return api_request(self, "GET", "/api/v1/accounts/search", params)
end

function Mastodon:content_search(query, options)
   options = options or {}
   options.q = query
   local params = generate_params(options)
   return api_request(self, "GET", "/api/v1/search", params)
end

function Mastodon:mutes()
   return api_request(self, "GET", "/api/v1/mutes")
end

function Mastodon:blocks()
   return api_request(self, "GET", "/api/v1/blocks")
end

function Mastodon:favourites()
   return api_request(self, "GET", "/api/v1/favourites")
end
Mastodon.favorites = Mastodon.favourites

function Mastodon:follow_requests(id, options)
   local params = generate_params(options or {})
   return api_request(self, "GET", "/api/v1/follow_requests", params)
end

---
-- Post a status. Can optionally be in reply to another status and contain
-- up to four pieces of media (Uploaded via media_post()). media_ids can
-- also be the media dicts returned by media_post - they are unpacked
-- automatically.
-- 
-- The 'sensitive' boolean decides whether or not media attached to the post
-- should be marked as sensitive, which hides it by default on the Mastodon
-- web front-end.
-- 
-- The visibility parameter is a string value and matches the visibility
-- option on the /api/v1/status POST API endpoint. It accepts any of:
-- 'private' - post will be visible only to followers
-- 'unlisted' - post will be public but not appear on the public timeline
-- 'public' - post will be public
-- 
-- If not passed in, visibility defaults to match the current account's
-- privacy setting (private if the account is locked, public otherwise).
-- 
-- The spoiler_text parameter is a string to be shown as a warning before
-- the text of the status.  If no text is passed in, no warning will be
-- displayed.
-- 
-- Returns a toot dict with the new status.
function Mastodon:status_post(status, options)
   options = options or {}
   options.status = status
   options.visibility = options.visibility or ""

   local valid_visibilities = {
      private = true,
      public = true,
      unlisted = true,
      [""] = true,
   }
   if not valid_visibilities[options.visibility:lower()] then
      return nil, 'Invalid visibility value! Acceptable values are ' .. str(valid_visibilities)
   end
   
   if not options.sensitive then
      options.sensitive = nil
   end

   if options.media_ids then
      local media_ids_proper = {}
      for _, media_id in ipairs(options.media_ids) do
         table.insert(media_ids_proper, type(media_id) == "table" and media_id.id or media_id)
      end
      options.media_ids = media_ids_proper
   end
   
   local params = generate_params(options, {})
   return api_request(self, "POST", "/api/v1/statuses", params)
end

function Mastodon:toot(status)
   return self:status_post(status)
end

function Mastodon:status_delete(id)
   return api_request(self, "DELETE", "/api/v1/statuses/" .. tostring(id))
end

function Mastodon:status_reblog(id)
   return api_request(self, "POST", "/api/v1/statuses/" .. tostring(id) .. "/reblog")
end

function Mastodon:status_unreblog(id)
   return api_request(self, "POST", "/api/v1/statuses/" .. tostring(id) .. "/unreblog")
end

function Mastodon:status_favourite(id)
   return api_request(self, "POST", "/api/v1/statuses/" .. tostring(id) .. "/favourite")
end
Mastodon.status_favorite = Mastodon.status_favourite

function Mastodon:status_unfavourite(id)
   return api_request(self, "POST", "/api/v1/statuses/" .. tostring(id) .. "/unfavourite")
end
Mastodon.status_unfavorite = Mastodon.status_unfavourite

function Mastodon:account_follow(id)
   return api_request(self, "POST", "/api/v1/accounts/" .. tostring(id) .. "/follow")
end

function Mastodon:account_unfollow(id)
   return api_request(self, "POST", "/api/v1/accounts/" .. tostring(id) .. "/unfollow")
end

function Mastodon:account_block(id)
   return api_request(self, "POST", "/api/v1/accounts/" .. tostring(id) .. "/block")
end

function Mastodon:account_unblock(id)
   return api_request(self, "POST", "/api/v1/accounts/" .. tostring(id) .. "/unblock")
end

function Mastodon:account_mute(id)
   return api_request(self, "POST", "/api/v1/accounts/" .. tostring(id) .. "/mute")
end

function Mastodon:account_unmute(id)
   return api_request(self, "POST", "/api/v1/accounts/" .. tostring(id) .. "/unmute")
end

function Mastodon:follow_request_authorize(id)
   return api_request(self, "POST", "/api/v1/follow_requests/" .. tostring(id) .. "/authorize")
end

function Mastodon:follow_request_reject(id)
   return api_request(self, "POST", "/api/v1/follow_requests/" .. tostring(id) .. "/reject")
end

---
-- Post an image. media_file can either be image data or
-- a file name. If image data is passed directly, the mime
-- type has to be specified manually, otherwise, it is
-- determined from the file name.
-- 
-- Return nil and an error message if the mime type of the
-- passed data or file can not be determined properly.
-- 
-- Returns a media dict. This contains the id that can be used in
-- status_post to attach the media file to a toot.
function Mastodon:media_post(media_file, mime_type)
   if not mime_type and lfs.attributes(media_file) then
      mime_type = mimetypes.guess(media_file)
   end

   if not mime_type then
      return nil, 'Could not determine mime type or data passed directly without mime type.'
   end
   
   local rnd = {}
   for _ = 1, 10 do
      local n = math.random(0, 35)
      table.insert(rnd, n < 10 and string.char(48 + n) or string.char(55 + n))
   end
   local random_suffix = table.concat(rnd)

   local extension = "bin"
   for ext, mime in pairs(mimedb.extensions) do
      if mime == mime_type then
         extension = ext
         break
      end
   end

   local file_name = "mastodonluaupload_" + tostring(os.time()) + "_" + random_suffix .. "." .. extension
   local media_file_description = { file_name, media_file, mime_type }
   return api_request(self, "POST", "/api/v1/media/", nil, { file = media_file_description })
end

return mastodon
