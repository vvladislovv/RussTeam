--!nonstrict
-- RussTeam — перенос изменений между разными проектами Roblox Studio.
--
-- Этот файл только связывает части:
--   Config     — пределы, списки классов и свойств
--   Serialize  — свойства в JSON и обратно
--   Tree       — обход проекта и сравнение снимков
--   Apply      — применение чужих изменений
--   Net        — разговор с сервером
--   Panel      — панель в Studio
--
-- Настройки живут в Config, а не здесь.

local HttpService   = game:GetService("HttpService")
local ChangeHistory = game:GetService("ChangeHistoryService")
local StudioService = game:GetService("StudioService")
local Players       = game:GetService("Players")
local RunService    = game:GetService("RunService")

local Config    = require(script.Config)
local Serialize = require(script.Serialize)
local Tree      = require(script.Tree)
local Apply     = require(script.Apply)
local Net       = require(script.Net)
local Panel     = require(script.Panel)

local VERSION       = Config.VERSION
local AUTO_TICK     = Config.AUTO_TICK
local TICK_MAX      = Config.TICK_MAX
local CHUNK_EVENTS  = Config.CHUNK_EVENTS
local MAX_CONFLICTS = Config.MAX_CONFLICTS
local BIG_CHANGE    = Config.BIG_CHANGE
local MAX_INSTANCES = Config.MAX_INSTANCES
local VERBOSE       = Config.VERBOSE

--==============================================================
-- Состояние
--==============================================================

local S = {
	connected    = false,
	statusText   = "не подключен",
	meId         = 0,
	meName       = "?",
	roster       = {},
	history      = {},
	conflicts    = {},
	bigPending   = nil,
	autoOn       = true,
	myPending    = 0,
	presenceNote = nil,
	devShown     = false,
}

local cfg          = { server = "", key = "", channel = "" }
local knownIds     = {}
local cursors      = {}
local lastSnapshot = {}
local bigApproved  = false
local busy         = false
local tick         = AUTO_TICK

local function log(fmt, ...)
	if VERBOSE then print("[RussTeam] " .. string.format(fmt, ...)) end
end

local function logError(fmt, ...)
	warn("[RussTeam] " .. string.format(fmt, ...))
end

local function addHistory(text)
	table.insert(S.history, 1, { at = os.time(), text = text })
	while #S.history > 30 do table.remove(S.history) end
end

local function safeId(v)
	return (tostring(v):gsub("[^%w%-_]", "_"))
end

local function whoAmI()
	local ok, id = pcall(function() return StudioService:GetUserId() end)
	S.meId = (ok and id and id > 0) and id or 0
	local okName, name = pcall(function() return Players:GetNameFromUserIdAsync(S.meId) end)
	if okName and name then
		S.meName = name
	elseif S.meId > 0 then
		S.meName = "id" .. tostring(S.meId)
	else
		local saved = plugin:GetSetting("anonId")
		if not saved then
			saved = math.random(100000, 999999)
			plugin:SetSetting("anonId", saved)
		end
		S.meId = saved
		S.meName = "гость-" .. tostring(saved)
	end
end

Apply.setErrorSink(logError)

--==============================================================
-- Кто в канале
--==============================================================

-- Кто пришёл и кто ушёл. Сообщение короткое и живёт минуту, потом гаснет —
-- список участников и без него говорит, кто на месте.
local NOTE_LIFE = 60
local noteAt = 0

local function notePresence(list)
	local now = os.time()
	local came, gone = {}, {}

	for id, rec in pairs(list) do
		local active = type(rec) == "table" and rec.at and (now - rec.at) < Config.IDLE_AFTER
		local name = (type(rec) == "table" and rec.name) or id
		if id ~= tostring(S.meId) then
			if active and not knownIds[id] then
				table.insert(came, name)
				knownIds[id] = name
			elseif not active and knownIds[id] then
				table.insert(gone, knownIds[id])
				knownIds[id] = nil
			end
		end
	end

	-- пропавших из переклички совсем тоже считаем ушедшими
	for id, name in pairs(knownIds) do
		if list[id] == nil then
			table.insert(gone, name)
			knownIds[id] = nil
		end
	end

	local parts = {}
	if #came > 0 then
		table.insert(parts, table.concat(came, ", ") .. (#came == 1 and " подключился" or " подключились"))
	end
	if #gone > 0 then
		table.insert(parts, table.concat(gone, ", ") .. (#gone == 1 and " отключился" or " отключились"))
	end
	if #parts > 0 then
		S.presenceNote = table.concat(parts, ", ")
		noteAt = now
		addHistory(S.presenceNote)
	elseif S.presenceNote and (now - noteAt) > NOTE_LIFE then
		S.presenceNote = nil
	end
end

--==============================================================
-- Приём и применение
--==============================================================

local function saveCursors()
	local ok, enc = pcall(function() return HttpService:JSONEncode(cursors) end)
	if ok then plugin:SetSetting("cursors_" .. safeId(cfg.channel), enc) end
end

local function applyBatches(batches)
	local events, byAuthor = {}, {}
	for _, b in ipairs(batches) do
		local owner = tostring(b.author)
		byAuthor[owner] = math.max(byAuthor[owner] or 0, b.n or 0)
		for _, ev in ipairs(b.events or {}) do
			table.insert(events, ev)
		end
	end
	if #events == 0 then return 0, {} end

	-- Предохранитель: очень большую пачку сразу не применяем, иначе один
	-- сбойный обмен молча снесёт полпроекта.
	if #events > BIG_CHANGE and not bigApproved then
		S.bigPending = { batches = batches, count = #events }
		S.statusText = string.format("подключен · пришло сразу %d изменений — подтверди внизу", #events)
		return 0, {}
	end
	bigApproved = false
	S.bigPending = nil

	local recording = ChangeHistory:TryBeginRecording("RussTeam: приём изменений")
	local localSnap, index = Tree.scan()
	Apply.setBaseline(lastSnapshot)
	local got = Apply.applyEvents(events, localSnap, index, "напарник")
	if recording then
		ChangeHistory:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end

	for owner, n in pairs(byAuthor) do
		cursors[owner] = math.max(cursors[owner] or 0, n)
	end
	saveCursors()

	-- Один объект не должен попадать в список конфликтов дважды.
	for _, c in ipairs(got) do
		local dup = false
		for _, have in ipairs(S.conflicts) do
			if have.sid == c.sid then dup = true break end
		end
		if not dup then table.insert(S.conflicts, c) end
	end
	while #S.conflicts > MAX_CONFLICTS do table.remove(S.conflicts, 1) end

	lastSnapshot = (Tree.scan())
	return #events - #got, got
end

--==============================================================
-- Один оборот обмена
--==============================================================

local function syncOnce(manual)
	if not RunService:IsEdit() then
		S.statusText = "подключен · идёт запуск игры, обмен на паузе"
		return
	end

	local snap, _, count = Tree.scan()
	local events = Tree.diff(lastSnapshot, snap)
	S.myPending = #events

	local since, hasAny = {}, false
	for k, v in pairs(cursors) do
		since[k] = v
		hasAny = true
	end

	local function makeBody(chunk)
		return {
			channel = cfg.channel,
			me      = tostring(S.meId),
			name    = S.meName,
			place   = tostring(game.PlaceId),
			ver     = VERSION,
			auto    = S.autoOn,
			edit    = true,
			pending = S.myPending,
			since   = hasAny and since or {},
			events  = chunk,
		}
	end

	-- Крупное отправляем порциями: в один запрос Roblox больше нескольких
	-- мегабайт не вывозит.
	local chunks = {}
	if #events > CHUNK_EVENTS then
		local part = {}
		for i, ev in ipairs(events) do
			table.insert(part, ev)
			if #part >= CHUNK_EVENTS or i == #events then
				table.insert(chunks, part)
				part = {}
			end
		end
		addHistory(string.format("изменений много (%d) — отправляю %d порциями", #events, #chunks))
	elseif #events > 0 then
		chunks = { events }
	end

	local res, err
	if #chunks == 0 then
		res, err = Net.post("/v1/sync", makeBody(nil))
	else
		for i, chunk in ipairs(chunks) do
			res, err = Net.post("/v1/sync", makeBody(chunk))
			if err then break end
			if i < #chunks then task.wait(0.2) end
		end
	end
	if err then
		S.statusText = "сбой обмена · " .. err
		tick = math.min(tick * 2, TICK_MAX)
		return
	end

	tick = AUTO_TICK
	S.roster = res.roster or S.roster
	notePresence(S.roster)

	local sent = 0
	if res.n then
		lastSnapshot = snap
		S.myPending = 0
		sent = #events
		addHistory(string.format("отправлено %d", sent))
	end

	if Tree.wasTruncated() then
		logError("обход остановлен на %d объектах — часть проекта НЕ синхронизируется", MAX_INSTANCES)
		addHistory(string.format("проект больше %d объектов — часть не уходит!", MAX_INSTANCES))
	end

	local applied, got = applyBatches(res.batches or {})
	if applied > 0 then
		local who = {}
		for _, b in ipairs(res.batches or {}) do who[b.authorName or "?"] = true end
		local names = {}
		for n in pairs(who) do table.insert(names, n) end
		addHistory(string.format("принято %d от %s", applied, table.concat(names, ", ")))
	end
	if #got > 0 then
		addHistory(string.format("конфликтов: %d", #got))
	end

	if res.dropped and res.dropped > 0 then
		logError("сервер выбросил %d непрочитанных пачек: не хватило места", res.dropped)
		addHistory(string.format("ВНИМАНИЕ: сервер выбросил %d пачек", res.dropped))
	end

	if S.bigPending then return end
	if res.more then
		S.statusText = "подключен · есть ещё, доберу следующим заходом"
	elseif applied > 0 or sent > 0 then
		S.statusText = string.format("подключен · принято %d, отправлено %d, объектов %d",
			applied, sent, count)
	elseif #S.conflicts > 0 then
		S.statusText = string.format("подключен · конфликтов %d", #S.conflicts)
	else
		S.statusText = "подключен · всё синхронно"
	end
end

--==============================================================
-- Подключение
--==============================================================

-- Всё, что человек вписал, запоминаем сразу и независимо от того,
-- получилось подключиться или нет. Переспрашивать одно и то же — худшее,
-- что может делать программа.
-- Настройки плагина живут отдельно у каждой установки: поставил из каталога
-- вместо файла — и поля пустые. Поэтому адрес сервера и канал дублируем в сам
-- проект, атрибутами на ServerStorage. Ключ там НЕ храним: место можно
-- опубликовать или передать, и ключ утечёт вместе с ним.
local PLACE_SERVER  = "__RussTeamServer"
local PLACE_CHANNEL = "__RussTeamChannel"

local function placeStore()
	local ok, svc = pcall(function() return game:GetService("ServerStorage") end)
	return ok and svc or nil
end

local function rememberInPlace()
	local store = placeStore()
	if not store then return end
	pcall(function()
		store:SetAttribute(PLACE_SERVER, cfg.server)
		store:SetAttribute(PLACE_CHANNEL, cfg.channel)
	end)
end

local function recallFromPlace()
	local store = placeStore()
	if not store then return nil, nil end
	local okS, srv = pcall(function() return store:GetAttribute(PLACE_SERVER) end)
	local okC, chan = pcall(function() return store:GetAttribute(PLACE_CHANNEL) end)
	return okS and srv or nil, okC and chan or nil
end

local function remember()
	plugin:SetSetting("server", cfg.server)
	plugin:SetSetting("key", cfg.key)
	plugin:SetSetting("channel", cfg.channel)
	rememberInPlace()
end

local function doConnect(silent)
	local chan, srv, key = Panel.fields()
	cfg.channel = chan:gsub("%s", "")
	cfg.server  = srv:gsub("%s", "")
	cfg.key     = key:gsub("%s", "")
	remember()

	if cfg.server == "" then
		S.connected = false
		S.statusText = "не подключен · впиши адрес сервера"
		Panel.showSetup(true)
		return
	end
	if cfg.key == "" then
		S.connected = false
		S.statusText = "не подключен · впиши ключ доступа"
		Panel.showSetup(true)
		return
	end
	if cfg.channel == "" or #cfg.channel < 4 or cfg.channel:match("[^%w%-_]") then
		S.connected = false
		S.statusText = "не подключен · код канала: буквы, цифры, дефис, от 4 знаков"
		return
	end

	whoAmI()
	Net.configure(cfg.server, cfg.key)

	local health, err = Net.talk("GET", "/health")
	if err then
		S.connected = false
		S.statusText = "не подключен · " .. err
		return
	end
	if not health or health.service ~= "russteam" then
		S.connected = false
		S.statusText = "не подключен · по этому адресу отвечает не RussTeam"
		return
	end

	local saved = plugin:GetSetting("cursors_" .. safeId(cfg.channel))
	if saved then
		local okJson, tbl = pcall(function() return HttpService:JSONDecode(saved) end)
		cursors = (okJson and type(tbl) == "table") and tbl or {}
	else
		cursors = {}
	end

	lastSnapshot = (Tree.scan())
	S.connected = true
	S.statusText = "подключен · канал " .. cfg.channel
	if not silent then log("подключен как %s, сервер %s", S.meName, cfg.server) end
end

--==============================================================
-- Обработчики панели
--==============================================================

local function guard(fn, what)
	if busy then return end
	busy = true
	S.statusText = what .. "…"
	Panel.refresh()
	task.spawn(function()
		local ok, err = pcall(fn)
		if not ok then
			S.statusText = "ошибка: " .. tostring(err)
			logError("%s", tostring(err))
		end
		busy = false
		pcall(Panel.refresh)
	end)
end

local handlers = {
	scan = Tree.scan,
	applyProps = Apply.applyProps,
	flushRefs = Apply.flushRefs,

	onConnect = function()
		if S.connected then
			S.connected = false
			S.roster = {}
			knownIds = {}
			S.presenceNote = nil
			S.statusText = "не подключен · обмен остановлен"
			addHistory("отключился")
			Panel.refresh()
			return
		end
		guard(function()
			doConnect(false)
			if S.connected then
				addHistory("подключился, догоняю накопленное")
				syncOnce(true)
			end
		end, "подключаюсь")
	end,

	onSync = function()
		if not S.connected then
			S.statusText = "не подключен · сначала подключись"
			Panel.refresh()
			return
		end
		guard(function() syncOnce(true) end, "обмениваюсь")
	end,

	onToggleAuto = function()
		S.autoOn = not S.autoOn
		plugin:SetSetting("auto", S.autoOn)
		addHistory(S.autoOn and "живой режим включён" or "живой режим выключен")
		if S.autoOn and S.connected then
			guard(function() syncOnce(false) end, "обмениваюсь")
		else
			Panel.refresh()
		end
	end,

	onAcceptBig = function()
		if not S.bigPending then return end
		guard(function()
			bigApproved = true
			local batches = S.bigPending.batches
			S.bigPending = nil
			local applied = applyBatches(batches)
			addHistory(string.format("подтверждено вручную: принято %d", applied))
		end, "переношу")
	end,
}

Panel.create(plugin, S, handlers)

--==============================================================
-- Живой режим
--==============================================================

do
	local saved = plugin:GetSetting("auto")
	S.autoOn = (saved == nil) or (saved == true)
end

task.spawn(function()
	while true do
		task.wait(tick)
		if S.connected and not busy then
			busy = true
			local ok, err = pcall(function()
				if S.autoOn then
					syncOnce(false)
				end
			end)
			busy = false
			if not ok then
				S.statusText = "ошибка обмена: " .. tostring(err)
				logError("сбой обмена: %s", tostring(err))
			end
			pcall(Panel.refresh)
		end
	end
end)

task.defer(function()
	-- Если плагин переустановили, поля пустые — берём запас из проекта.
	local chan0, srv0, key0 = Panel.fields()
	if srv0 == "" or chan0 == "" then
		local srvP, chanP = recallFromPlace()
		if (srv0 == "" and srvP) or (chan0 == "" and chanP) then
			Panel.setFields(chan0 == "" and chanP or nil, srv0 == "" and srvP or nil, nil)
			if key0 == "" then
				Panel.showSetup(true)
				S.statusText = "не подключен · адрес и канал восстановлены, впиши ключ"
			end
		end
	end

	local chan, srv, key = Panel.fields()
	if chan ~= "" and srv ~= "" and key ~= "" then
		guard(function()
			doConnect(true)
			if S.connected then syncOnce(false) end
		end, "подключаюсь")
	else
		Panel.refresh()
	end
end)

do
	local okV, v = pcall(version)
	log("RussTeam %s загружен, Studio %s", VERSION, okV and tostring(v) or "?")
end
