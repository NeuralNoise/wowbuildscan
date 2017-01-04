local M = {_NAME="LuaCASC", _VERSION="LuaCASC 1.4"}
local plat, bin = require("casc.platform"), require("casc.bin")
local blte, bspatch = require("casc.blte"), require("casc.bspatch")
local encoding, root = require("casc.encoding"), require("casc.root")

local uint32_le, uint32_be, uint40_be, to_bin, to_hex, ssub
	= bin.uint32_le, bin.uint32_be, bin.uint40_be, bin.to_bin, bin.to_hex, string.sub

local DATA_DIRECTORIES = {"Data", "HeroesData"}

M.locale = {} do
	for k,v in pairs({US=0x02, KR=0x04, FR=0x10, DE=0x20, CN=0x40, ES=0x80, TW=0x0100, GB=0x0200, MX=0x1000, RU=0x2000, BR=0x4000, IT=0x8000, PT=0x010000}) do
		local isCN, m = k == "CN", v * 2
		M.locale[k] = function(loc, tf)
			return loc % m >= v and ((tf % 16 > 7) == isCN and 2 or 1) or nil
		end
	end
end
local function defaultLocale(loc, tf, cdn)
	return (loc % 0x400 < 0x200 and 0 or 2) + (tf % 16 < 8 and 1 or 0) - (cdn and 4 or 0)
end

local function checkMD5(casc, msg, hash, ...)
	if casc.verifyHashes and type((...)) == "string" then
		local actual, expected = plat.md5((...)), #hash == 16 and to_hex(hash) or hash
		if actual ~= expected then
			return nil, ("%s verification failed (got %s; expected %s)"):format(msg, actual, expected)
		end
	end
	return ...
end
local function maybeCheckMD5s(casc, eMD5, cMD5, ...)
	local cnt, head = ...
	if cnt then
		if eMD5 then
			local ok, err = checkMD5(casc, "encoding hash", eMD5, head)
			if not ok then
				return nil, err
			end
		end
		if cMD5 then
			return checkMD5(casc, "content hash", cMD5, cnt)
		end
	end
	return ...
end

local function check_args(name, idx, v, t1, t2, ...)
	if t1 then
		local tt = type(v)
		if tt ~= t1 and tt ~= t2 then
			error('Invalid argument #' .. idx .. " to " .. name .. ": " .. t1 .. " expected; got " .. tt, 3)
		end
		return check_args(name, idx+1, ...)
	end
end
local function readFile(...)
	local path = plat.path(...)
	if not path then
		return nil, "no path specified"
	end
	local h, err = io.open(path, "rb")
	if h then
		local c = h:read("*a")
		h:close()
		return c
	end
	return h, err
end
local function readURL(...)
	local url = plat.url(...)
	if url then
		return plat.http(url)
	else
		return nil, "no URL specified"
	end
end
local function readCache(cpath, lpath, url)
	local ret, err = nil, "no read requested"
	if cpath then
		ret, err = readFile(cpath)
	end
	if not ret and lpath then
		ret, err = readFile(lpath)
	end
	if not ret and url then
		ret, err = readURL(url)
		if ret and cpath then
			local h = io.open(cpath, "wb")
			if h then
				h:write(ret)
				h:close()
			end
		end
	end
	return ret, err
end
local function readCacheCommon(casc, cname, ...)
	return readCache(plat.path(casc.cache, cname), plat.path(casc.base, ...), plat.url(casc.cdn, ...))
end
local function prefixHash(h)
	local a, b, c = h:match("((%x%x)(%x%x).+)")
	return b, c, a
end
local function adjustHash(h)
	return #h == 32 and h:lower() or to_hex(h), #h == 16 and h or to_bin(h)
end
local function toBinHash(h)
	return #h == 32 and to_bin(h) or h
end
local function toHexHash(h)
	return #h == 16 and to_hex(h) or h
end

local function parseInfoData(data)
	local hname, htype, hn, ret = {}, {}, 1, {}
	local i, s, line = data:gmatch("[^\n]+")
	line = i(s, line)
	for e in line:gmatch("[^|]+") do
		hn, hname[hn], htype[hn] = hn + 1, e:match("^([^!]+)!([^:]+)")
	end
	
	for e in i,s,line do
		local l, ln = {}, 1
		for f in e:gmatch("|?([^|]*)") do
			if f ~= "" then
				l[hname[ln]] = htype[ln] == "DEC" and tonumber(f) or f
			end
			ln = ln + 1
		end
		if ln > 1 then
			ret[#ret+1] = l
		end
	end

	return ret
end
local function parseConfigData(data, into)
	local ret, ln, last, lr = type(into) == "table" and into or {}, 1
	for l in data:gmatch("[^\r\n]+") do
		if l:match("^%s*[^#].-%S") then
			local name, args = l:match("^%s*(%S+)%s*=(.*)$")
			if name then
				last, ln, lr = {}, 1, ret[name]
				if lr then
					if type(lr[1]) == "table" then
						lr[#lr + 1] = last
					else
						ret[name] = {ret[name], last}
					end
				else
					ret[name] = last
				end
			end
			for s in (args or l):gmatch("%S+") do
				last[ln], ln = s, ln + 1
			end
		end
	end
	return ret
end
local function parseLocalIndexData(data, into)
	-- TODO: Check whether these have MD5 blocks -- they have blizzhash blocks, many levels.
	local pos, sub, len = 8 + uint32_le(data), data.sub
	pos = pos + ((16 - pos % 16) % 16)
	len, pos = uint32_le(data, pos), pos + 9
	assert(len % 18 == 0, "Index data block length parity check")
	
	for i=1, len/18 do
		local key = sub(data, pos, pos + 8)
		if not into[key] then
			into[key] = uint40_be(data, pos+8)
		end
		pos = pos + 18
	end

	return len/18
end

local getContent
local function getPatchedContent(casc, rec, ctag, cMD5)
	local cnt, err
	for i=1, rec and #rec or 0, 3 do
		local oc = getContent(casc, rec[i], nil, ctag, true)
		if oc then
			local pMD5 = toHexHash(rec[i+1])
			local pc, _perr = maybeCheckMD5s(casc, nil, pMD5, plat.http(plat.url(casc.cdn, "patch", prefixHash(pMD5))))
			if pc then
				cnt, err = maybeCheckMD5s(casc, nil, cMD5, bspatch.patch(oc, pc))
				if cnt then
					return cnt
				end
				casc.log("WARN", "Failed to apply patch: " .. tostring(err), toHexHash(rec[i]) .. "+" .. pMD5)
			end
		end
	end
	return nil, err
end
function getContent(casc, eMD5, cMD5, ctag, useOnlyLocalData)
	local cnt, err
	local eMD5, ehash = adjustHash(eMD5)
	local lcache = ctag and plat.path(casc.cache, ctag .. "." .. eMD5)

	local ch = lcache and io.open(lcache, "rb")
	if ch then
		cnt, err = maybeCheckMD5s(casc, nil, cMD5, ch:read("*a"))
		ch:close()
		if cnt then return cnt end
	end

	local ehash9 = ssub(ehash, 1, 9)
	local lloc = casc.base and casc.index and casc.index[ehash9]
	if lloc then
		cnt, err = maybeCheckMD5s(casc, eMD5, cMD5, blte.readArchive(plat.path(casc.base, "data", ("data.%03d"):format(lloc / 2^30)), lloc % 2^30))
		if cnt then return cnt end
	end
	
	if casc.cdn and not useOnlyLocalData then
		if cMD5 and casc.patchRecipes then
			cnt, err = getPatchedContent(casc, casc.patchRecipes[toBinHash(cMD5)], ctag, cMD5)
		end
	
		local cloc = not cnt and (casc.indexCDN and casc.indexCDN[ehash9] or eMD5)
		if cloc then
			local range, name = cloc:match("(%d+%-%d+):(.+)")
			local url = plat.url(casc.cdn, "data", prefixHash(name or cloc))
			cnt, err = plat.http(url, range and {Range="bytes=" .. range})
			if cnt then
				cnt, err = maybeCheckMD5s(casc, eMD5, cMD5, blte.readData(cnt))
			end
		end
	end
	
	if cnt and lcache then
		local ch = io.open(lcache, "wb")
		if ch then
			ch:write(cnt)
			ch:close()
		end
	end
	if cnt then return cnt end
	
	return nil, err or("Could not retrieve " .. eMD5 .. "/" .. (cMD5 and toHexHash(cMD5) or "?"))
end
local function getContentByContentHash(casc, cMD5, ctag)
	local cMD5, chash = adjustHash(cMD5)
	local err, cnt = "no encodings of " .. cMD5 .. " are known"
	local keys = casc.encoding:getEncodingHash(chash)
	
	for j=1,keys and 2 or 0 do
		for i=1,#keys do
			cnt, err = getContent(casc, keys[i], cMD5, ctag, j == 1)
			if cnt then
				return cnt
			end
		end
	end
	
	return nil, err
end
local function getContentHashForPath(casc, path, rateFunc)
	local rateFunc, idx, seen, score, vscore, chash = rateFunc or casc.locale, casc.index
	
	for _, vchash, vinfo in casc.root:getFileVariants(path) do
		local isLocal, keys = false, idx and casc.encoding:getEncodingHash(vchash)
		for i=1, keys and #keys or 0 do
			local key = keys[i]
			if idx[ssub(key, 1, 9)] then
				isLocal = true
				break
			end
		end
		seen, vscore = 1, rateFunc(vinfo[2], vinfo[1], isLocal)
		if vscore and vscore >= (score or vscore) then
			score, chash = vscore, vchash
		end
	end
	
	if not chash then
		return nil, ("no %s of %q are accessible"):format(seen and "acceptable variants" or "variants", path)
	end
	return chash
end
local function defaultLog(mtype, text, extra)
	if mtype == "FAIL" then
		io.stderr:write(text .. (extra ~= nil and " " .. tostring(extra) or "") .. "\n")
	end
end

local indexCDN_mt = {} do
	local function parseCDNIndexData(name, data, into)
		-- TODO: these have MD5 integrity blocks within.
		local dlen, p = #data-28, 0
		for i=1, math.floor(dlen/4100) - math.floor(dlen/844600) do
			for pos=p, p+4072, 24 do
				local len = uint32_be(data, pos+16)
				if len > 0 then
					local ofs = uint32_be(data, pos+20)
					into[ssub(data, pos+1, pos+9)] = ofs .. "-" .. (ofs+len-1) .. ":" .. name
				end
			end
			p = p + 4096
		end
	end
	
	function indexCDN_mt:__index(ehash)
		local archives, casc, v = self._source, self._owner
		for i=#archives, 1, -1 do
			v, archives[i] = archives[i]
			local idat, err = readCache(
				plat.path(casc.cache, "index." .. v),
				plat.path(casc.base, "indices", v .. ".index"),
				plat.url(casc.cdn, "data", prefixHash(v .. ".index"))
			)
			if err and not idat then
				casc.log("FAIL", "Failed to load CDN index", v)
			end
			parseCDNIndexData(v, idat, self)
			if rawget(self, ehash) then
				break
			end
		end
		if #archives == 0 then
			self._owner, self._source = nil
			setmetatable(self, nil)
		end
		return self[ehash]
	end
end

local handle = {}
local handle_mt = {__index=handle}
function handle:readFile(path, lang, cache)
	if cache == nil then cache = self.cacheFiles end
	lang = M.locale[lang] or lang
	check_args("cascHandle:readFile", 1, path, "string", "string", lang, "function", "nil", cache, "boolean","nil")

	local chash, err = getContentHashForPath(self, path, lang)
	if not chash then
		return nil, err
	end
	
	return getContentByContentHash(self, chash, cache and "file")
end
function handle:readFileByEncodingHash(ehash, cache)
	if cache == nil then cache = self.cacheFiles end
	check_args("cascHandle:readFileByEncodingHash", 1, ehash,"string","string", cache,"boolean","nil")
	return getContent(self, ehash, nil, cache and "file")
end
function handle:readFileByContentHash(chash, cache)
	if cache == nil then cache = self.cacheFiles end
	check_args("cascHandle:readFileByContentHash", 1, chash, "string", "string", cache,"boolean","nil")
	return getContentByContentHash(self, chash, cache and "file")
end
function handle:getFileContentHash(path, lang)
	lang = M.locale[lang] or lang
	check_args("cascHandle:getFileContentHash", 1, path, "string", "string", lang, "function", "nil")

	local chash, err = getContentHashForPath(self, path, lang)
	if not chash then
		return nil, err
	end
	return toHexHash(chash)
end
function handle:getFileVariants(path)
	check_args("cascHandle:getFileVariants", 1, path, "string", "string")

	local ret = {}
	for _, vchash, vinfo in self.root:getFileVariants(path) do
		local key, langs, ln = to_hex(vchash), {}, 1
		for lang, rate in pairs(M.locale) do
			if rate(vinfo[2], vinfo[1], true) then
				langs[ln], ln = lang, ln + 1
			end
		end
		ret[key] = langs
	end
	
	if not next(ret) then
		return nil, ("no variants of %q are known"):format(path)
	end
	return ret
end
function handle:setLocale(locale)
	check_args("cascHandle:setLocale", 1, M.locale[locale] or locale, "function", "nil")
	self.locale = M.locale[locale] or locale or defaultLocale
end
function handle_mt:__tostring()
	return ("CASC: <%s;%s %s;%s>"):format(tostring(self.base), tostring(self.cdn), tostring(self.bkey), tostring(self.ckey))
end

local function parseOpenArgs(...)
	local conf, extra = ...
	if type(conf) == "table" then
		assert(type(conf.bkey) == "string", 'casc.open: conf.bkey must be a string')
		if not (conf.ckey and conf.cdn) then conf.ckey, conf.cdn = nil end
		for s in ("base cdn ckey cache"):gmatch("%S+") do
			assert(conf[s] == nil or type(conf[s]) == "string", ('casc.open: if specified, conf.%s must be a string'):format(s))
		end
		assert(type(conf.base) == "string" or type(conf.cdn) == "string", 'casc.open: at least one of (conf.base, (conf.cdn, conf.ckey)) must be specified')
		conf.locale = M.locale[conf.locale] or (conf.locale == nil and defaultLocale) or conf.locale
		conf.verifyHashes = conf.verifyHashes == nil or conf.verifyHashes
		conf.log = conf.log == nil and defaultLog or conf.log
		conf.usePatchEntries = conf.usePatchEntries == nil or conf.usePatchEntries
		conf.mergeInstall = conf.mergeInstall ~= nil or conf.mergeInstall or false
		conf.requireRootFile = conf.requireRootFile or false
		conf.cacheFiles = conf.cacheFiles or false
		assert(conf.locale == nil or type(conf.locale) == "function", 'casc.open: if specified, conf.locale must be a function or a valid casc.locale key')
		assert(type(conf.verifyHashes) == 'boolean', 'casc.open: if specified, conf.verifyHashes must be a boolean')
		assert(type(conf.log) == 'function', 'casc.open: if specified, conf.log must be a function')
		assert(type(conf.usePatchEntries) == 'boolean', 'casc.open: if specified, conf.usePatchEntries must be a boolean')
		assert(type(conf.requireRootFile) == 'boolean', 'casc.open: if specified, conf.requireRootFile must be a boolean')
		assert(type(conf.mergeInstall) == 'boolean' or type(conf.mergeInstall) == 'string', 'casc.open: if specified, conf.mergeInstall must be a string or a boolean')
		assert(type(conf.cacheFiles) == 'boolean', 'casc.open: if specified, conf.cacheFiles must be a boolean')
		
		local c2 = {}
		for k in ("base bkey cdn ckey cache verifyHashes locale buildInfo mergeInstall usePatchEntries requireRootFile cacheFiles log"):gmatch("%S+") do
			c2[k] = conf[k]
		end
		return setmetatable(c2, handle_mt)
		
	elseif type(extra) == "string" and #extra == 32 then
		local base, build, cdn, cdnKey, cache = ... -- pre-1.3 casc.open() syntax
		return parseOpenArgs({base=base, bkey=build, cdn=cdn, ckey=cdnKey, cache=cache, verifyHashes=false})
		
	elseif type(conf) == "string" then
		local base, build, cdn, cdnKey, _, info
		if conf:match("^http://.+#.") then
			build, cdn, cdnKey, _, info = M.cdnbuild(conf:match("(.+)#(.+)"))
		else
			build, cdn, cdnKey, _, info = M.localbuild(plat.path(conf, ".build.info"), M.selectActiveBuild)
			for i=1,build and #DATA_DIRECTORIES or 0 do
				base = plat.path(conf, DATA_DIRECTORIES[i])
				local ch = io.open(plat.path(base, "config", prefixHash(build)), "r")
				if ch then
					ch:close()
					break
				end
				base = nil
			end
		end
		if not build then
			return nil, cdn
		end
		local c = {base=base, bkey=build, cdn=cdn, ckey=cdnKey, verifyHashes=true, buildInfo=info}
		if type(extra) == "table" then
			for k,v in pairs(extra) do
				c[k] = v
			end
		end
		return parseOpenArgs(c)
	end
	error('Syntax: handle = casc.open({conf} or "rootPath"[, {conf}] or "patchURL"[, {conf}])', 3)
end

function M.conf(root, options)
	check_args("casc.conf", 1, root,"string",nil, options,"table","nil")
	return parseOpenArgs(root, options)
end

function M.open(conf, options, ...)
	local casc, err = parseOpenArgs(conf, options, ...)
	if not casc then return nil, err end
	casc.log("OPEN", "Loading build configuration", casc.bkey)
	local cdat, err = checkMD5(casc, "hash", casc.bkey, readCacheCommon(casc, "build." .. casc.bkey, "config", prefixHash(casc.bkey)))
	if not cdat then return nil, "build configuration: " .. tostring(err) end
	casc.conf = parseConfigData(cdat)
	
	if casc.ckey then
		casc.log("OPEN", "Loading CDN configuration", casc.ckey)
		local ccdat, err = checkMD5(casc, "hash", casc.ckey, readCacheCommon(casc, "cdn." .. casc.ckey, "config", prefixHash(casc.ckey)))
		if not ccdat then return nil, "cdn configuration: " .. tostring(err) end
		parseConfigData(ccdat, casc.conf)
		local source, archives = {}, casc.conf.archives
		for i=1,#archives do
			source[i] = archives[i]
		end
		casc.indexCDN = setmetatable({_owner=casc, _source=source}, indexCDN_mt)
	end
	
	if casc.base then
		casc.log("OPEN", "Scanning local indices")
		local indexFiles, index, ic, ii = {}, {}, 0, 1
		for _, f in plat.files(plat.path(casc.base, "data"), "*.idx") do
			local id = f:match("(%x%x)%x+%....$"):lower()
			local old = indexFiles[id]
			if not old or old < f then
				indexFiles[id], ic = f, ic + 1
			end
		end
		for _, f in pairs(indexFiles) do
			casc.log("OPEN", "Loading local indices", f, ii, ic)
			local idat, err = readFile(f)
			if not idat then return nil, "local index " .. f .. ": " .. tostring(err) end
			parseLocalIndexData(idat, index)
			ii = ii + 1
		end
		casc.index = index
	end

	local pckey, pdkey = casc.conf["patch-config"] and casc.conf["patch-config"][1], casc.conf.patch and casc.conf.patch[1]
	if pckey and pdkey and casc.usePatchEntries then
		casc.log("OPEN", "Loading patch configuration", pckey)
		local pcdat, err = checkMD5(casc, "hash", pckey, readCacheCommon(casc, "pconf." .. pckey, "config", prefixHash(pckey)) )
		if not pcdat then return nil, "patch configuration: " .. tostring(err) end
		parseConfigData(pcdat, casc.conf)
		
		local recipes, entries = {}, casc.conf["patch-entry"]
		for i=1,entries and #entries or 0 do
			local v = entries[i]
			local chash = toBinHash(v[2])
			local rt, rn = recipes[chash] or {}
			recipes[chash], rn = rt, #rt+1
			for j=7,#v,4 do
				rt[rn], rt[rn+1], rt[rn+2], rn = toBinHash(v[j]), toBinHash(v[j+2]), tonumber(v[j+3]), rn + 3
			end
		end
		
		casc.patchRecipes = recipes
	end
	
	local ekey = casc.conf.encoding[2]
	casc.log("OPEN", "Loading encoding file", ekey)
	local edat, err = getContent(casc, ekey, casc.conf.encoding[1], "encoding")
	if not edat then return nil, "encoding file: " .. tostring(err) end
	casc.encoding = encoding.parse(edat)
	
	local rkey = casc.conf.root[1]
	casc.log("OPEN", "Loading root file", rkey)
	local rdat, err = getContentByContentHash(casc, rkey, "root")
	if rdat then
		casc.root, err = root.parse(rdat)
	end
	if not casc.root then
		if casc.requireRootFile then
			return nil, "root file: " .. tostring(err)
		end
		casc.root = root.empty()
		casc.log("FAIL", err or "Failed to load root file", rkey)
	end
	casc.requireRootFile = nil
	
	if casc.mergeInstall and casc.conf.install then
		local ikey = casc.conf.install[1]
		casc.log("OPEN", "Loading install data", ikey)
		local ins, err = getContentByContentHash(casc, ikey, "install")
		if not ins then return nil, "missing install file: " .. tostring(err) end
		local universal, filter = {0, 0xffffff}, casc.mergeInstall ~= true and casc.mergeInstall or nil
		for name, hash in require("casc.install").files(ins, filter) do
			casc.root:addFileVariant(name, hash, universal)
		end
	else
		casc.mergeInstall = nil
	end
	casc.log("OPEN", "Ready")
	
	return casc
end


function M.cdnbuild(patchBase, region)
	check_args("casc.cdnbuild", 1, patchBase, "string", "string", region, "string", "nil")
	
	local dat, err = plat.http(plat.url(patchBase, "versions"))
	if not dat then return nil, "patch versions retrieval: " .. tostring(err) end
	local versions = parseInfoData(dat)

	dat, err = plat.http(plat.url(patchBase, "cdns"))
	if not dat then return nil, "patch CDN retrieval: " .. tostring(err) end
	local cdns = parseInfoData(dat)
	
	local reginfo = {}
	for i=1,#versions do
		local v = versions[i]
		reginfo[v.Region] = {cdnKey=v.CDNConfig, buildKey=v.BuildConfig, build=v.BuildId, version=v.VersionsName}
	end
	for i=1,#cdns do
		local c = cdns[i]
		if reginfo[c.Name] then
			reginfo[c.Name].cdnBase = c.Hosts and c.Path and plat.url("http://", c.Hosts:match("%S+"), c.Path)
		end
	end
	if reginfo[region] and reginfo[region].cdnBase then
		local r = reginfo[region]
		return r.buildKey, r.cdnBase, r.cdnKey, r.version, r
	elseif region == nil then
		return reginfo, versions, cdns
	end
end
function M.localbuild(buildInfoPath, selectBuild)
	check_args("casc.localbuild", 1, buildInfoPath, "string", "string", selectBuild, "function", "nil")
	
	local dat, err = readFile(buildInfoPath)
	if not dat then return nil, err end
	
	local info = parseInfoData(dat)
	if type(selectBuild) == "function" and info then
		local ii = info[selectBuild(info)]
		if ii then
			return ii["Build Key"], plat.url("http://", ii["CDN Hosts"]:match("%S+"), ii["CDN Path"]), ii["CDN Key"], ii["Version"], ii
		end
	elseif info then
		local branches = {}
		for i=1,#info do
			local ii = info[i]
			local curl = plat.url("http://", ii["CDN Hosts"]:match("%S+"), ii["CDN Path"])
			branches[ii.Branch] = {cdnKey=ii["CDN Key"], buildKey=ii["Build Key"], version=ii["Version"], cdnBase=curl}
		end
		return branches, info
	end
end

function M.selectActiveBuild(buildInfo)
	check_args("casc.selectActiveBuild", 1, buildInfo, "table", "table")
	
	for i=1,#buildInfo do
		if buildInfo[i].Active == 1 then
			return i
		end
	end
end

return M