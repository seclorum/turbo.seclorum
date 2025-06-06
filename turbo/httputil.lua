--- Turbo.lua HTTP Utilities module
-- Contains the HTTPHeaders and HTTPParser classes, which parses request and
-- response headers and also offers utilities to build request headers.
--
-- Also offers a few functions for parsing GET URL parameters, and different
-- POST data types.
--
-- Copyright John Abrahamsen 2011, 2012, 2013
--
-- "Permission is hereby granted, free of charge, to any person obtaining a copy of
-- this software and associated documentation files (the "Software"), to deal in
-- the Software without restriction, including without limitation the rights to
-- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
-- of the Software, and to permit persons to whom the Software is furnished to do
-- so, subject to the following conditions:
--
-- The above copyright notice and this permission notice shall be included in all
-- copies or substantial portions of the Software.
--
-- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
-- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
-- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
-- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
-- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
-- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
-- SOFTWARE."

local log =         require "turbo.log"
local status_codes = require "turbo.http_response_codes"
local deque =       require "turbo.structs.deque"
local buffer =      require "turbo.structs.buffer"
local escape =      require "turbo.escape"
local util =        require "turbo.util"
local platform =    require "turbo.platform"
local ffi =         require "ffi"
local libturbo_parser = util.load_libtffi()

require "turbo.cdef"
require "turbo.3rdparty.middleclass"

local fast_assert = util.fast_assert
local b = string.byte

local httputil = {} -- httputil namespace

--- Must match the enum in http-parser.h!
local method_map = {
    [0] = "DELETE",
    "GET",
    "HEAD",
    "POST",
    "PUT",
    "CONNECT",
    "OPTIONS",
    "TRACE",
    "COPY",
    "LOCK",
    "MKCOL",
    "MOVE",
    "PROPFIND",
    "PROPPATCH",
    "SEARCH",
    "UNLOCK",
    "BIND",
    "REBIND",
    "UNBIND",
    "ACL",
    "REPORT",
    "MKACTIVITY",
    "CHECKOUT",
    "MERGE",
    "MSEARCH",
    "NOTIFY",
    "SUBSCRIBE",
    "UNSUBSCRIBE",
    "PATCH",
    "PURGE",
    "MKCALENDAR",
    "LINK",
    "UNLINK",
    "SOURCE"
}


local function MAX(a,b) return a > b and a or b end

--*************** HTTP Header parsing ***************


--- URL Field table.
httputil.UF = {
    SCHEMA           = 0
  , HOST             = 1
  , PORT             = 2
  , PATH             = 3
  , QUERY            = 4
  , FRAGMENT         = 5
  , USERINFO         = 6
}

--- HTTP header type. Use on HTTPHeaders initialize() to specify
-- header type to parse.
httputil.hdr_t = {
    HTTP_REQUEST    = 0,
    HTTP_RESPONSE   = 1,
    HTTP_BOTH       = 2
}

local javascript_types = {
    ["application/javascript"] = true,
    ["application/json"] = true,
    ["application/x-javascript"] = true,
    ["text/x-javascript"] = true,
    ["text/x-json"] = true
}


--- HTTPParser Class
-- Class for creation and parsing of HTTP headers.
httputil.HTTPParser = class("HTTPParser")

--- Pass request headers as parameters to parse them into
-- the returned object.
function httputil.HTTPParser:initialize(hdr_str, hdr_t)
    if hdr_str and hdr_t then
        if hdr_t == httputil.hdr_t["HTTP_REQUEST"] then
            self:parse_request_header(hdr_str)
        elseif hdr_t == httputil.hdr_t["HTTP_RESPONSE"] then
            self:parse_response_header(hdr_str)
        end
    end
    -- Arguments are only parsed on-demand.
    self._arguments_parsed = false
end

--- Parse standalone URL and populate class instance with values.
-- HTTPParser.get_url_field must be used to read out values.
-- @param url (String) URL string.
-- @note Will throw error if URL does not parse correctly.
function httputil.HTTPParser:parse_url(url)
    if type(url) ~= "string" then
        error("URL parameter is not a string")
    end
    self.http_parser_url = ffi.new("struct http_parser_url")
    local rc = libturbo_parser.http_parser_parse_url(
        url,
        url:len(),
        0,
        ffi.cast("struct http_parser_url *", self.http_parser_url))
    if rc ~= 0 then
       error("Could not parse URL")
    end
    if not self.url then
        self.url = url
    end
end

--- Get a URL field.
-- @param UF_prop (Number) Available fields described in the httputil.UF table.
-- @return nil if not found, else the string value is returned.
function httputil.HTTPParser:get_url_field(UF_prop)
    if not self.url then
        self:get_url()
    end
    if not self.http_parser_url then
        self:parse_url(self.url)
    end
    if libturbo_parser.url_field_is_set(
        self.http_parser_url, UF_prop) == true then
        local url = ffi.cast("const char *", self.url)
        local field = ffi.string(
            url+self.http_parser_url.field_data[UF_prop].off,
            self.http_parser_url.field_data[UF_prop].len)
        return field
    end
    -- Field is not set.
    return nil
end

--- Get URL.
-- @return Currently set URI or nil if not set.
function httputil.HTTPParser:get_url()
    if self.url then
        return self.url
    else
        if not self.tpw then
            error("No URL or header has been parsed. Can not return URL.")
        end
        if self.tpw.url_str == nil then
            error("No URL available for request headers.")
        end
        self.url = ffi.string(self.tpw.url_str, self.tpw.url_sz)
    end
    return self.url
end

--- Get HTTP method
-- @return Current method as string or nil if not set.
function httputil.HTTPParser:get_method()
    if not self.tpw then
        error("No header has been parsed. Can not return method.")
    end
    if self.tpw.parser.method > #method_map then
        error("Unknown method. Can not return method.")
    end
    return method_map[self.tpw.parser.method]
end

--- Get the HTTP version.
-- @return Currently set version as string or nil if not set.
function httputil.HTTPParser:get_version()
    return string.format(
        "HTTP/%d.%d",
        self.tpw.parser.http_major,
        self.tpw.parser.http_minor)
end

--- Get the status code.
-- @return Status code and status code message if set, else nil.
function httputil.HTTPParser:get_status_code()
    if not self.tpw then
        error("No header has been parsed. Can not return status code.")
    elseif self.hdr_t ~= httputil.hdr_t["HTTP_RESPONSE"] then
        error("Parsed header not a HTTP response header.")
    end
    return self.tpw.parser.status_code, status_codes[self.status_code]
end

local function _unescape(s)
    local n = tonumber(s,16)
    if n then return string.char(n) end
end

--- Internal function to parse ? and & separated key value fields.
-- @param uri (String)
local function _parse_arguments(uri)
    local arguments = {}
    local elements = 0;

    for k, v in uri:gmatch("([^&=]+)=([^&]+)") do
        elements = elements + 1;
        if (elements > 256) then
            -- Limit to 256 elements, which "should be enough for everyone".
            break
        end
        v = v:gsub("+", " "):gsub("%%(%w%w)", _unescape);
        if not arguments[k] then
            arguments[k] = v;
        else
            if type(arguments[k]) == "string" then
                local tmp = arguments[k];
                arguments[k] = {tmp};
            end
            table.insert(arguments[k], v);
        end
    end
    return arguments
end

--- Get URL argument of the header.
-- @param argument Key of argument to get value of.
-- @return If argument exists then the argument is either returned
-- as a table if multiple values is given the same key, or as a string if the
-- key only has one value. If argument does not exist, nil is returned.
function httputil.HTTPParser:get_argument(argument)
    if not self._arguments_parsed then
        self._arguments = _parse_arguments(self:get_url_field(httputil.UF.QUERY))
        self._arguments_parsed = true
    end
    local arguments = self:get_arguments()
    if arguments then
        if type(arguments[argument]) == "table" then
            return arguments[argument]
        elseif type(arguments[argument]) == "string" then
            return { arguments[argument] }
        end
    end
end

--- Get all arguments of the header as a table.
-- @return (Table) Table with keys and values.
function httputil.HTTPParser:get_arguments()
    if not self._arguments_parsed then
        local query = self:get_url_field(httputil.UF.QUERY)
        if query then
           self._arguments = _parse_arguments(query)
        end
        self._arguments_parsed = true
    end
    return self._arguments
end

--- Get given key from header key value section.
-- @param key (String) The key to get.
-- @param caseinsensitive (Boolean) If true then the key will be matched without
-- regard for case sensitivity.
-- @return The value of the key, or nil if not existing. May return a table if
-- multiple keys are set.
local strncasecmp
if platform.__LINUX__ or platform.__UNIX__ then
    strncasecmp = ffi.C.strncasecmp
elseif platform.__WINDOWS__ then
    -- Windows does not have strncasecmp, but has strnicmp, which does the
    -- thing.
    strncasecmp = ffi.C._strnicmp
end
function httputil.HTTPParser:get(key, caseinsensitive)
    local value
    local c = 0
    local hdr_sz = tonumber(self.tpw.hkv_sz)
    -- If caseinsensitive is nil then default to true.
    if caseinsensitive == nil then
        caseinsensitive = true
    end

    if hdr_sz <= 0 then
        return nil
    end
    if caseinsensitive then
        -- Case insensitive key.
        for i = 0, hdr_sz-1 do
            local field = self.tpw.hkv[i]
            local key_sz = key:len()
            if field.key_sz == key_sz then
                if strncasecmp(
                    field.key,
                    key,
                    field.key_sz) == 0 then
                    local str = ffi.string(field.value, field.value_sz)
                    if c == 0 then
                        value = str
                        c = 1
                    elseif c == 1 then
                        value = {value, str}
                        c = 2
                    else
                        value[#value+1] = str
                        c = c + 1
                    end
                end
            end
        end
    else
        -- Case sensitive key.
        for i = 0, hdr_sz-1 do
            local field = self.tpw.hkv[i]
            local key_sz = key:len()
            if field.key_sz == key_sz then
                if ffi.C.memcmp(
                    field.key,
                    key,
                    MAX(field.key_sz, key_sz)) == 0 then
                    local str = ffi.string(field.value, field.value_sz)
                    if c == 0 then
                        value = str
                        c = 1
                    elseif c == 1 then
                        value = {value, str}
                        c = 2
                    else
                        value[#value+1] = str
                        c = c + 1
                    end
                end
            end
        end
    end
    return value, c
end

--- Parse HTTP request or response headers.
-- Populates the class with all data in headers.
-- @param hdr_str (String) HTTP header string.
-- @param hdr_t (Number) A number defined in httputil.hdr_t representing header
-- type.
-- @note Will throw error on parsing failure.
function httputil.HTTPParser:parse_header(hdr_str, hdr_t)
    -- Ensure the string is not GCed while we are still using it by keeping a
    -- reference to it. There is no way for LuaJIT to know we are still
    -- using pointers to it.
    self.hdr_str = hdr_str
    self.hdr_t = hdr_t
    local tpw = libturbo_parser.turbo_parser_wrapper_init(
        hdr_str,
        hdr_str:len(),
        hdr_t)
    if tpw ~= nil then
        ffi.gc(tpw, libturbo_parser.turbo_parser_wrapper_exit)
    else
        error("libturbo_parser could not allocate memory for struct.")
    end
    self.tpw = tpw
    if libturbo_parser.turbo_parser_check(self.tpw) ~= true then
        error(
            string.format(
                "libturbo_parser could not parse HTTP header. %s %s",
                ffi.string(libturbo_parser.http_errno_name(
                    self.tpw.parser.http_errno)),
                ffi.string(libturbo_parser.http_errno_description(
                    self.tpw.parser.http_errno))))
    end
    if self.tpw.headers_complete == false then
        error("libturbo_parser could not parse header. Unknown error.")
    end
end

--- Parse HTTP response headers.
-- Populates the class with all data in headers.
-- @param raw_headers (String) HTTP header string.
-- @note Will throw error on parsing failure.
function httputil.HTTPParser:parse_response_header(raw_headers)
    self:parse_header(raw_headers, httputil.hdr_t["HTTP_RESPONSE"])
end

--- Parse HTTP request headers.
-- Populates the class with all data in headers.
-- @param raw_headers (String) HTTP header string.
-- @note Will throw error on parsing failure.
function httputil.HTTPParser:parse_request_header(raw_headers)
    self:parse_header(raw_headers, httputil.hdr_t["HTTP_REQUEST"])
end

--- Parse HTTP post arguments.
function httputil.parse_post_arguments(data)
    if type(data) ~= "string" then
        error("data argument not a string.")
    end
    return _parse_arguments(data)
end

local DASH = string.byte('-')
local CR = string.byte'\r'
local LF = string.byte'\n'
-- finds the start of a line
local function find_line_start(str,pos, inc)
    if not inc then inc = 1 end
    local skipped = -1
    -- skip any non-CRLF chars
    repeat
        b = str:byte(pos)
        if b == nil then return nil end
        pos = pos + inc
        skipped = skipped+1
    until (b==CR) or (b==LF)

    local b2 = str:byte(pos)
    if b2 == nil then return nil end
    if (b2 == CR) or (b2 == LF) then
        if b ~= b2 then
            pos = pos + inc
        end
    end
    return pos, skipped
end

-- @return end position of token, token string
local function getRFC822Atom(str,pos)
    local fpos, lpos, token = str:find('([^%c%s()<>@,;:\\"/[%]?=]+)', pos)
    return lpos, token
end

--- Parse multipart form data.

local function parse_multipart_headers(boundary_headers)
    local argument = {}

    for fname, fvalue, content_kvs in
        boundary_headers:gmatch("([^%c%s:]+):%s*([^\r\n;]*);?([^\n\r]*)") do
        fname = fname:lower()
        if fvalue == "form-data" and fname=="content-disposition" then
            argument[fname] = {}
            local p = 1
            repeat
                p, key = getRFC822Atom(content_kvs,p)
                if p == nil then break end
                if content_kvs:byte(p+1) ~= string.byte('=') then
                    break
                end
                p=p+2
                local _, p2, val = content_kvs:find('^"([^"]+)"',p)
                if not p2 then
                    p2, val = getRFC822Atom(content_kvs,p)
                    if not p2 then break end
                end
                p = p2+1
                if key=="name" then
                    name=val
                end
                argument[fname][key] = val
            until false
        else
            if fname=="content-type" then
                fvalue = fvalue:lower()
            elseif fname=="charset" or
                fname=="content-transfer-encoding" then
                fvalue = fvalue:lower()
            end
            argument[fname] = fvalue
        end
    end
    return argument, name
end

function httputil.parse_multipart_data(data, boundary)
    local arguments = {}
    local p1, p2, b1, b2

    boundary = "--" .. boundary
    p1, p2 = data:find(boundary, 1, true)
    b1 = find_line_start(data,p2+1)
    repeat
        p1, p2 = data:find(boundary, p2, true)
        if p1 == nil then break end
        b2 = find_line_start(data,p1-1,-1)
        do
            local boundary_headers
            local h1, h2, v1, skipped
            v1 = b1
            repeat
                h1 = v1
                v1 = find_line_start(data,v1)
                if v1 == nil then goto next_boundary end
            until skipped ~= 0
            repeat
                h2 = v1-1
                v1, skipped = find_line_start(data,v1)
                if v1 == nil then goto next_boundary end
            until skipped == 0
            boundary_headers = data:sub(h1,h2)
            boundary_headers = boundary_headers:gsub("([^%c%s:]-):",
                      function(s) return string.gsub(s,"%u", function(c)
                            return string.lower(c) end) .. ":"
                      end)
            if not boundary_headers then
                goto next_boundary
            end
            do
                local argument, name = parse_multipart_headers(boundary_headers)
                if not name then
                    goto next_boundary
                end
                argument[1] = data:sub(v1, b2)
                if argument["content-transfer-encoding"] == "base64" then
                    argument[1] = escape.base64_decode(argument[1])
                end
                if javascript_types[argument["content-type"]] then
                    argument[1] = escape.unescape(argument[1])
                end
                if arguments[name] then
                    arguments[name][#arguments[name] +1] = argument
                else
                    arguments[name] = { argument }
                end
            end
        end
::next_boundary::
        b1 = find_line_start(data,p2+1)
    until (b1+1 > #data) or
        (data:byte(p2+1) == DASH and data:byte(p2+2) == DASH)
    return arguments
end

--- streaming parsing multipart/form data

ffi.cdef[[
typedef void FILE;
size_t fwrite(const void *ptr, size_t size, size_t nmemb, FILE *stream);
int fflush ( FILE * stream );
]]

httputil.StreamingParser = class("StreamingParser")

function httputil.StreamingParser:initialize(serverhandle)
    self.connection = serverhandle

    local content_length = serverhandle._request.headers:get("Content-Length")
    content_length = tonumber(content_length)
    self.content_length = content_length

    local content_type = serverhandle._request.headers:get("Content-Type")
    self.content_type = content_type
    -- RFC2046
    local boundary = content_type:match(
        "boundary=[\"]?([0-9a-zA-Z'()+_,-./:=? ]*[0-9a-zA-Z'()+_,-./:=?])")
    if boundary then
        self.boundary = boundary
        boundary = "--" .. boundary
        local begin_boundary = boundary
        local next_boundary = "\r\n" .. boundary
        local close_boundary = "\r\n" .. boundary .. "--"

        self.begin_boundary = begin_boundary
        self.begin_boundary_ptr = ffi.cast("char*", begin_boundary)
        self.next_boundary = next_boundary
        self.next_boundary_ptr = ffi.cast("char*", next_boundary)
        self.close_boundary = close_boundary
        self.close_boundary_ptr = ffi.cast("char*", close_boundary)
        self.next_boundary_size = #next_boundary
        self.close_boundary_size = #close_boundary

    end

    self.consumed_bytes = 0
    self.processed_bytes = 0

    serverhandle.arguments = {}
    self.arguments = serverhandle.arguments
    self.streaming_buffer = buffer(5120)
    self._ptr = ffi.cast("char *", "")
    self._len = 0
    self._used = 0
    self.state = "start"
    self._total_used = 0
    self._total_get = 0

    local kwargs = serverhandle.kwargs
    local large_body_bytes
    if kwargs then
        large_body_bytes = kwargs.large_body_bytes
    end
    self.large_body_bytes = large_body_bytes or 512

    return self
end

function httputil.StreamingParser:load_chunk(chunk)
    self.streaming_buffer:append_right(chunk.ptr, chunk.len)
    self._ptr, self._len = self.streaming_buffer:get()
    self._used = 0
    self._total_get = self._total_get + self._len
end

function httputil.StreamingParser:unused()
    return self._ptr + self._used
end

function httputil.StreamingParser:unused_len()
    return self._len - self._used
end

function httputil.StreamingParser:shift(bytes)
    self._used = self._used + bytes
    self._total_used = self._total_used + bytes
end

function httputil.StreamingParser:substrbytes(bytes)
    return ffi.string(self:unused(), bytes)
end

function httputil.StreamingParser:strfind(fstr, flen)
    local ptr = util.str_find(self:unused(), fstr, self:unused_len(), flen)
    if ptr then
        return ptr - self:unused()
    else
        return nil
    end
end

function httputil.StreamingParser:possible_boundary()
    local boundary = self.next_boundary_ptr
    local boundary_size = self.next_boundary_size
    local start_find, rest_len
    if self:unused_len() > boundary_size then
        start_find = self._ptr + self._len - boundary_size
        rest_len = boundary_size
    else
        start_find = self:unused()
        rest_len = self:unused_len()
    end
    -- find just onebyte consider as possible
    local ptr = util.str_find(start_find, boundary, rest_len, 1)
    if ptr then
        return ptr - self:unused()
    else
        return nil
    end
end

function httputil.StreamingParser:buffer_keep_unused()
    local buf_start_ptr, sz = self.streaming_buffer:get()
    local all_used = self._ptr - buf_start_ptr + self._used
    if self:unused_len() > 0 then
        self.streaming_buffer:pop_left(all_used)
    else
        self.streaming_buffer:clear()
    end
end

function httputil.StreamingParser:parse_large_multipart_body(chunk)
    self:load_chunk(chunk)
    assert(self.boundary, "need boundary")

    local state_function_map = {
        start = self._state_begin_boundary,
        headers = self._state_part_headers,
        body = self._state_part_body,
        large_body = self._state_part_large_body,
        close = self._state_close,
    }

    -- state transfer
    local next_state
    local state = self.state
    repeat
        next_state = state_function_map[state](self)
        state = next_state or state
        self.state = state
    until next_state == false

    self:buffer_keep_unused()
end

function httputil.StreamingParser:_state_begin_boundary()
    local start_offset = self:strfind(self.begin_boundary_ptr, self.next_boundary_size -2)
    if start_offset then
        -- ignore all data before begin boundary
        self:shift(self.next_boundary_size -2)
        return "headers"
    else
        return false
    end
end

function httputil.StreamingParser:_state_part_headers()
    local start_offset = self:strfind(ffi.cast("char*", "\r\n\r\n"), 4)
    if start_offset ~= nil then
        if start_offset > 512 then error("part header too long") end
        self:_push_streaming_multipart_headers(self:substrbytes(start_offset))
        self:shift(start_offset + 4)
        return "body"
    else
        return false
    end
end

function httputil.StreamingParser:_push_streaming_multipart_headers(headers_string)
    local arguments = self.arguments
    local argument, name = parse_multipart_headers(headers_string)
    assert(name, "part header Content-Disposition: MUST contains name=\"xxx\"")

    self._name = name
    if arguments[name] then
        arguments[name][#arguments[name] +1] = argument
    else
        arguments[name] = { argument }
    end
end


function httputil.StreamingParser:_state_part_body()
    local boundary_size = self.next_boundary_size
    local nb_start_offset = self:strfind(self.next_boundary_ptr, self.next_boundary_size)
    local cb_start_offset = self:strfind(self.close_boundary_ptr, self.close_boundary_size)
    local is_large_body = false
    if self:unused_len() >= self.large_body_bytes then
        if nb_start_offset then
            is_large_body = nb_start_offset >= self.large_body_bytes
        elseif cb_start_offset then
            is_large_body = cb_start_offset >= self.large_body_bytes
        else
            is_large_body = true
        end
    end
    if is_large_body then
        local tmpname = os.tmpname()
        local file = io.open(tmpname, "w")
        assert(file, "open file faild:" .. tmpname)
        self._tmpname = tmpname
        self._tmpfile = file
        self._tmplen = 0
        return "large_body"
    elseif nb_start_offset then
        self:_push_streaming_multipart_body(self:substrbytes(nb_start_offset))
        self:shift(nb_start_offset + boundary_size)
        return "headers"
    elseif cb_start_offset then
        self:_push_streaming_multipart_body(self:substrbytes(cb_start_offset))
        self:shift(cb_start_offset + boundary_size)
        return "close"
    else
        return false
    end
end

function httputil.StreamingParser:_push_streaming_multipart_body(body_string)
    local name = self._name
    local arguments = self.arguments
    local argument = arguments[name][#arguments[name]]
    argument[1] = body_string
    if argument["content-transfer-encoding"] == "base64" then
        argument[1] = escape.base64_decode(argument[1])
    end
    if javascript_types[argument["content-type"]] then
        argument[1] = escape.unescape(argument[1])
    end
end

function httputil.StreamingParser:_state_part_large_body()
    local boundary_size = self.next_boundary_size
    local nb_start_offset = self:strfind(self.next_boundary_ptr, self.next_boundary_size)
    local cb_start_offset = self:strfind(self.close_boundary_ptr, self.close_boundary_size)
    local tmpname = self._tmpname
    if not tmpname then
        tmpname = os.tmpname()
        self._tmpname = tmpname
    end
    local file = self._tmpfile
    if not file then
        file = io.open(tmpname, "a")
        self._tmpfile = file
    end

    if nb_start_offset then
        self:_write_to_file(nb_start_offset, file)
        self:_push_streaming_multipart_large_body()
        self:shift(nb_start_offset + boundary_size)
        return "headers"
    elseif cb_start_offset then
        self:_write_to_file(cb_start_offset, file)
        self:_push_streaming_multipart_large_body()
        self:shift(cb_start_offset + boundary_size)
        return "close"
    elseif self:unused_len() >= 2*boundary_size then
        -- to keep possiblely boundary data in buffer for checking in next reading
        local offset = self:possible_boundary()
        if offset ~= nil then
            self:_write_to_file(offset, file)
            self:shift(offset)
        else
            self:_write_to_file(self:unused_len(), file)
            self:shift(self:unused_len())
        end
        return "large_body"
    else
        return false
    end
end

function httputil.StreamingParser:_write_to_file(len, file)
    ffi.C.fwrite(self:unused(), len, 1, file)
    ffi.C.fflush(file)
    self._tmplen = self._tmplen + len
end


function httputil.StreamingParser:_push_streaming_multipart_large_body()
    local name = self._name
    local arguments = self.arguments
    local argument = arguments[name][#arguments[name]]
    self._tmpfile:close()
    argument[1] = string.format("(save in %s)", self._tmpname)
    argument["filepath"] = self._tmpname
    argument["filelen"] = tonumber(self._tmplen)
    self._tmpname = nil
    self._tmpfile = nil
    self._name = nil
    self._tmplen = nil
end

function httputil.StreamingParser:_state_close()
    --collectgarbage()
    return false
end


--*************** HTTP Header generation ***************


--- HTTPHeaders Class
-- Class for creating HTTP headers in a programmatic fashion.
httputil.HTTPHeaders = class("HTTPHeaders")

function httputil.HTTPHeaders:initialize()
    self._fields = {}
end

--- Set URI.
-- @param uri (String)
function httputil.HTTPHeaders:set_uri(uri)
    if type(uri) ~= "string" then
        error("argument #1 not a string.")
    end
    self.uri = uri
end

--- Get current URI.
-- @return Currently set URI or nil if not set.
function httputil.HTTPHeaders:get_uri() return self.uri end

--- Set HTTP method.
-- @param method (String) Must be string, or error is raised.
function httputil.HTTPHeaders:set_method(method)
    if type(method) ~= "string" then
        error("argument #1 not a string.")
    end
    self.method = method
end

--- Get HTTP method
-- @return Current method as string or nil if not set.
function httputil.HTTPHeaders:get_method() return self.method end

--- Set the HTTP version.
-- Applies when building response headers only.
-- @param version (String) Version in string form, e.g "1.1" or "1.0"
-- Must be string or error is raised.
function httputil.HTTPHeaders:set_version(version)
    if type(version) ~= "string" then
       error("argument #1 not a string.")
    end
    self.version = version
end

--- Get the current HTTP version.
-- @return Currently set version as string or nil if not set.
function httputil.HTTPHeaders:get_version() return self.version end

--- Set the status code.
-- Applies when building response headers.
-- @param code (Number) HTTP status code to set. Must be number or
-- error is raised.
function httputil.HTTPHeaders:set_status_code(code)
    if type(code) ~= "number" then
       error("argument #1 not a number.")
    end
    if not status_codes[code] then
       error(string.format("Invalid HTTP status code given: %d", code))
    end
    self.status_code = code
end

--- Get the current status code.
-- @return Status code and status code message if set, else nil.
function httputil.HTTPHeaders:get_status_code()
    return self.status_code, status_codes[self.status_code]
end

--- Get given key from header key value section.
-- @param key (String) The key to get.
-- @param caseinsensitive (Boolean) If true then the key will be matched without
-- regard for case sensitivity.
-- @return The value of the key, or nil if not existing. May return a table if
-- multiple keys are set.
function httputil.HTTPHeaders:get(key, caseinsensitive)
    local value
    local cnt = 0
    if caseinsensitive == true then
        key = key:lower()
        for i = 1, #self._fields do
            if self._fields[i] and self._fields[i][1]:lower() == key then
                if cnt == 0 then
                    value = self._fields[i][2]
                    cnt = 1
                elseif cnt == 1 then
                    value = {value, self._fields[i][2]}
                    cnt = 2
                else
                    value[#value + 1] = self._fields[i][2]
                    cnt = cnt + 1
                end
            end
        end
    else
        for i = 1, #self._fields do
            if self._fields[i] and self._fields[i][1] == key then
                if cnt == 0 then
                    value = self._fields[i][2]
                    cnt = 1
                elseif cnt == 1 then
                    value = {value, self._fields[i][2]}
                    cnt = 2
                else
                    value[#value + 1] = self._fields[i][2]
                    cnt = cnt + 1
                end
            end
        end
    end
    return value, cnt
end

--- Add a key with value to the headers. Supports adding multiple values to
-- one key. E.g mutiple "Set-Cookie" header fields.
-- @param key (String) Key to add to headers. Must be string or error is raised.
-- @param value (String or Number) Value to associate with the key.
function httputil.HTTPHeaders:add(key, value)
    if type(key) ~= "string" then
       error("Key parameter must be a string.")
    end
    local t = type(value)
    if t == "string" then
        if value:find("\r\n", 1, true) then
            error("String value contain <CR><LF>, not allowed.")
        end
    elseif t ~= "number" then
        error("Value parameter must be a string or number.")
    end
    self._fields[#self._fields + 1] = {key, value}
end


--- Set a key with value to the headers. Overwiting existing key.
-- @param key (String) Key to set to headers. Must be string or error is raised.
-- @param value (String) Value to associate with the key.
function httputil.HTTPHeaders:set(key, value, caseinsensitive)
    if type(key) ~= "string" then
       error("Key parameter must be a string.")
    end
    local t = type(value)
    if t == "string" then
        if value:find("\r\n", 1, true) then
            error("String value contain <CR><LF>, not allowed.")
        end
    elseif t ~= "number" then
        error("Value parameter must be a string or number.")
    end
    self:remove(key, caseinsensitive)
    self:add(key, value)
end

--- Remove key from headers.
-- @param key (String) Key to remove from headers. Must be string or error is raised.
-- @param caseinsensitive (Boolean) If true then the key will be matched without
-- regard for case sensitivity.
function httputil.HTTPHeaders:remove(key, caseinsensitive)
    if type(key) ~= "string" then
       error("Key parameter must be a string.")
    end
    if caseinsensitive == false then
        for i = 1, #self._fields do
            if self._fields[i] and self._fields[i][1] == key then
                self._fields[i] = nil
            end
        end
    else
        key = key:lower()
        for i = 1, #self._fields do
            if self._fields[i] and self._fields[i][1]:lower() == key then
                self._fields[i] = nil
            end
        end
    end
end

--- Stringify data set in class as a HTTP request header.
-- @return (String) HTTP header string excluding final delimiter.
function httputil.HTTPHeaders:stringify_as_request()
    local buffer = buffer:new()
    for i = 1, #self._fields do
        if self._fields[i] then
            buffer:append_luastr_right(string.format("%s: %s\r\n",
                self._fields[i][1], self._fields[i][2]));
        end
    end
    return string.format("%s %s %s\r\n%s\r\n",
        self.method,
        self.uri,
        self.version,
        tostring(buffer))
end

--- Stringify data set in class as a HTTP response header.
-- If not "Date" field is set, it will be generated automatically.
-- @return (String) HTTP header string excluding final delimiter.
function httputil.HTTPHeaders:stringify_as_response()
    local buf = buffer:new()
    if not self:get("Date") then
        -- Add current time as Date header if not set already.
        self:add("Date", util.time_format_http_header(util.gettimeofday()))
    end
    for i = 1 , #self._fields do
        if self._fields[i] then
            -- string.format causes trace abort here.
            -- Just build keyword values by abuse.
            buf:append_luastr_right(self._fields[i][1])
            buf:append_luastr_right(": ")
            buf:append_luastr_right(tostring(self._fields[i][2]))
            buf:append_luastr_right("\r\n")
        end
    end
    return string.format("%s %d %s\r\n%s",
        self.version,
        self.status_code,
        status_codes[self.status_code],
        tostring(buf))
end

--- Convinience method to return HTTPHeaders:stringify_as_response on string
-- conversion.
function httputil.HTTPHeaders:__tostring()
    return self:stringify_as_response()
end

return httputil
