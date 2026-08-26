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

-- Этот файл — ПЛАГИН. Если его копию случайно оставили скриптом в дереве
-- проекта, при запуске игры он выполнится как обычный серверный скрипт,
-- где никакого plugin нет. Тихо выходим, а не падаем с ошибкой.
if not plugin then
	return
end

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
-- Одна копия на Studio
--==============================================================

-- Плагин легко оказывается установленным дважды: файлом в папке плагинов и
-- из каталога. Тогда в тулбаре две кнопки, две копии шлют в канал одно и то
-- же и мешают друг другу. Отметку ставим на CoreGui: она не сохраняется
-- в файл проекта и исчезает вместе со Studio.
local CLAIM = "__RussTeamActive"
local CLAIM_TTL = 12          -- отметку считаем живой столько секунд
local myClaim = HttpService:GenerateGUID(false)

local function claimHolder()
	local ok, cg = pcall(function() return game:GetService("CoreGui") end)
	return ok and cg or nil
end

local function readClaim()
	local holder = claimHolder()
	if not holder then return nil end
	local ok, raw = pcall(function() return holder:GetAttribute(CLAIM) end)
	if not ok or type(raw) ~= "string" then return nil end
	local okJson, data = pcall(function() return HttpService:JSONDecode(raw) end)
	return okJson and data or nil
end

local function writeClaim()
	local holder = claimHolder()
	if not holder then return end
	pcall(function()
		holder:SetAttribute(CLAIM, HttpService:JSONEncode({
			id = myClaim, ver = Config.VERSION, at = os.time(),
		}))
	end)
end

-- Сравнение версий по числам, а не по алфавиту: иначе «2.10» окажется
-- меньше «2.9» и новая копия уступит старой.
local function versionValue(v)
	local major, minor = tostring(v):match("^(%d+)%.(%d+)")
	if not major then return -1 end
	return tonumber(major) * 1000 + tonumber(minor)
end

-- Возвращает: можно ли работать, и кто мешает.
local function takeClaim()
	local other = readClaim()
	if other and other.id ~= myClaim and other.at and (os.time() - other.at) < CLAIM_TTL then
		local theirs = tostring(other.ver or "?")
		-- Новее — забираем работу себе, старее или та же — уступаем.
		if versionValue(theirs) >= versionValue(Config.VERSION) then
			return false, theirs
		end
	end
	writeClaim()
	return true, nil
end

local allowed, blockedBy = takeClaim()
if not allowed then
	warn(string.format("[RussTeam] уже запущена копия версии %s — эта (%s) отключилась. "
		.. "Удали лишнюю установку: Plugins → Manage Plugins",
		tostring(blockedBy), Config.VERSION))
	return
end

-- Держим отметку свежей, чтобы вторая копия видела: место занято.
task.spawn(function()
	while true do
		writeClaim()
		task.wait(5)
	end
end)

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
	scriptsBlocked = false,
	fullPending  = nil,
	progress     = nil,
	sendPending  = nil,
}

local cfg          = { server = "", key = "", channel = "" }
local knownIds     = {}
local cursors      = {}
local lastSnapshot = {}
local bigApproved  = false
local dedupeReady  = false   -- второе нажатие подтверждает уборку
local dedupeFound  = nil
local dedupeAt     = 0       -- когда нашли: список протухает
local retries      = {}      -- сколько раз пачка не легла
local fullPushId   = nil     -- идёт отправка проекта целиком
local incomingFull = {}      -- собираем части чужого полного снимка
local fullApproved = false   -- человек подтвердил приём всего проекта
local lastFullKeep = nil     -- состав последнего принятого полного снимка
local pruneReady   = false   -- второе нажатие подтверждает уборку лишнего
local pruneFound   = nil
local sendDelApproved = false   -- человек подтвердил отправку удалений
local honoredRequest = nil   -- на какую просьбу уже откликнулись
local wantFullPush = false   -- нас попросили прислать проект целиком
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

-- Две Studio одного человека — это два разных участника: у них разные проекты.
-- Если считать их одним, ленты и курсоры смешаются и правки будут теряться:
-- окно, которое синхронизировалось первым, «съест» пачку у второго.
local function participantId()
	return tostring(S.meId) .. "-" .. tostring(game.PlaceId)
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
		if id ~= participantId() then
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
	cursors["full"] = nil
	local ok, enc = pcall(function() return HttpService:JSONEncode(cursors) end)
	if ok then plugin:SetSetting("cursors_" .. safeId(cfg.channel) .. "_" .. safeId(game.PlaceId), enc) end
end

-- Собираем части чужого полного снимка. Прибираться в проекте можно
-- только когда пришли ВСЕ части: иначе снесём то, что просто ещё не доехало.
local function collectFull(b, events)
	local info = b.full
	if type(info) ~= "table" or not info.id then return false end

	local box = incomingFull[info.id]
	if not box then
		-- Новый снимок отменяет предыдущий: подтверждать надо самый свежий.
		for oldId in pairs(incomingFull) do
			if oldId ~= info.id then incomingFull[oldId] = nil end
		end
		box = { total = tonumber(info.total) or 1, parts = {}, events = {},
			at = os.time(), from = b.authorName or b.author }
		incomingFull[info.id] = box
	end
	if not box.parts[info.part] then
		box.parts[info.part] = true
		for _, ev in ipairs(events) do
			table.insert(box.events, ev)
		end
	end

	local have = 0
	for _ in pairs(box.parts) do have += 1 end
	box.have = have
	return true
end

-- Применение готового списка событий. Отдельно от applyBatches, чтобы
-- подтверждённый полный снимок можно было применить без поддельных пакетов.
local applyDirect

local function applyBatches(batches)
	local events, byAuthor = {}, {}
	local fullReady = nil

	for _, b in ipairs(batches) do
		local owner = tostring(b.author)
		byAuthor[owner] = math.max(byAuthor[owner] or 0, b.n or 0)
		local ancs = b.ancs
		local batchEvents = {}
		for _, ev in ipairs(b.events or {}) do
			-- Разворачиваем короткую ссылку обратно в родословную
			local rec = ev.rec or ev
			if ancs and rec.ancRef and not rec.anc then
				rec.anc = ancs[rec.ancRef]
			end
			table.insert(batchEvents, ev)
		end

		if collectFull(b, batchEvents) then
			local box = incomingFull[b.full.id]
			if box.have >= box.total then
				fullReady = b.full.id
			else
				addHistory(string.format("полный снимок: часть %d из %d", box.have, box.total))
			end
		else
			for _, ev in ipairs(batchEvents) do table.insert(events, ev) end
		end
	end

	-- Полный снимок собрался. Сам его не применяем: он МЕНЯЕТ ПРОЕКТ ЦЕЛИКОМ,
	-- включая удаление лишнего. Такое человек должен подтвердить.
	if fullReady and not fullApproved then
		local box = incomingFull[fullReady]
		S.fullPending = { id = fullReady, count = #box.events, from = box.from }
		S.statusText = string.format(
			"пришёл ВЕСЬ проект (%d объектов) — подтверди приём внизу", #box.events)
		addHistory(string.format("полный снимок собран: %d объектов, жду подтверждения",
			#box.events))

		-- Части уже у нас в памяти, поэтому курсор двигаем: иначе сервер
		-- будет присылать их снова и снова, а в статусе вечно «принято 0».
		for owner, n in pairs(byAuthor) do
			if owner ~= "full" then
				cursors[owner] = math.max(cursors[owner] or 0, n)
			end
		end
		saveCursors()

		-- Обычные изменения, пришедшие в том же заходе, применяем как всегда:
		-- ожидание снимка не должно останавливать текущую работу.
		if #events == 0 then
			return 0, {}, {}
		end
	end

	if fullReady and fullApproved then
		local box = incomingFull[fullReady]
		incomingFull[fullReady] = nil
		fullApproved = false
		S.fullPending = nil
		for _, ev in ipairs(box.events) do table.insert(events, ev) end
		addHistory(string.format("принимаю весь проект: %d объектов", #box.events))
	end
	if #events == 0 then return 0, {} end

	-- Предохранитель: очень большую пачку сразу не применяем, иначе один
	-- сбойный обмен молча снесёт полпроекта.
	-- Считаем удаления отдельно: они опаснее всего остального вместе взятого.
	local delCount = 0
	for _, ev in ipairs(events) do
		if (ev.op or (ev.rec and ev.rec.op)) == "del" then delCount += 1 end
	end
	if delCount > Config.MAX_AUTO_DELETE and not bigApproved then
		S.bigPending = { events = events, count = #events, deletions = delCount }
		S.statusText = string.format(
			"ВНИМАНИЕ: напарник удалил %d объектов — подтверди внизу, если это правда", delCount)
		addHistory(string.format("пришло %d УДАЛЕНИЙ — жду подтверждения", delCount))
		logError("пришло %d удалений. Если напарник этого не делал — не подтверждай "
			.. "и попроси его отправить проект целиком", delCount)
		for owner, n in pairs(byAuthor) do
			if owner ~= "full" then
				cursors[owner] = math.max(cursors[owner] or 0, n)
			end
		end
		saveCursors()
		return 0, {}, {}
	end

	if #events > BIG_CHANGE and not bigApproved then
		-- Держим события у себя и ОТМЕЧАЕМ ПАЧКИ ПРОЧИТАННЫМИ. Иначе сервер
		-- шлёт их снова каждые 12 секунд, подтверждение пересоздаётся,
		-- и приём не двигается с места — ровно как было с полным снимком.
		S.bigPending = { events = events, count = #events }
		S.statusText = string.format("подключен · пришло сразу %d изменений — подтверди внизу", #events)
		for owner, n in pairs(byAuthor) do
			if owner ~= "full" then
				cursors[owner] = math.max(cursors[owner] or 0, n)
			end
		end
		saveCursors()
		return 0, {}, {}
	end
	bigApproved = false
	S.bigPending = nil

	local recording = ChangeHistory:TryBeginRecording("RussTeam: приём изменений")
	local localSnap, index = Tree.scan()
	Apply.setBaseline(lastSnapshot)
	Apply.beginSession()
	local got, report = Apply.applyEvents(events, localSnap, index, "напарник")
	report = report or {}
	local reallyAppliedNothing = ((report.added or 0) + (report.adopted or 0)
		+ (report.changed or 0) + (report.created or 0) + (report.removed or 0)) == 0
	if recording then
		ChangeHistory:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end

	-- Курсор двигаем, только если пачка ЛЕГЛА. Иначе непринятое пропадало
	-- навсегда: сервер считал её прочитанной и больше не присылал.
	-- Но и вечно топтаться нельзя — после трёх попыток сдаёмся с криком.
	local failed = (report and report.skipped or 0) > 0 and reallyAppliedNothing
	for owner, n in pairs(byAuthor) do
		local key = tostring(owner) .. ":" .. tostring(n)
		if failed then
			retries[key] = (retries[key] or 0) + 1
			if retries[key] < 3 then
				addHistory(string.format("пачка не легла, попробую ещё (%d из 3)", retries[key]))
			else
				logError("пачка от %s не применилась трижды — пропускаю её, "
					.. "иначе обмен встанет", tostring(owner))
				addHistory("пачка не легла трижды — пропущена")
				cursors[owner] = math.max(cursors[owner] or 0, n)
				retries[key] = nil
			end
		else
			cursors[owner] = math.max(cursors[owner] or 0, n)
			retries[key] = nil
		end
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

	-- Конфликт про объект, которого больше нет, только мешает.
	for i = #S.conflicts, 1, -1 do
		local sid = S.conflicts[i].sid
		if sid and not index[sid] then
			table.remove(S.conflicts, i)
		end
	end

	-- Полный снимок: приводим проект в точное соответствие. Всё, чего нет
	-- у отправителя, убираем — иначе удалённое у него у нас остаётся навсегда.
	-- Уборки здесь НЕТ. Она удаляла целые ветки, когда признак оставался
	-- включённым от прошлого полного снимка. Теперь это отдельное действие
	-- с предпросмотром, а приём только добавляет и правит.
	lastSnapshot = (Tree.scan())
	-- Принятым считаем только то, что действительно легло в проект.
	report = report or {}
	local reallyApplied = (report.added or 0) + (report.adopted or 0)
		+ (report.changed or 0) + (report.created or 0) + (report.removed or 0)
	return reallyApplied, got, report
end

-- Применяет список событий как есть: тем же путём, что и обычный приём,
-- но без разбора пачек и курсоров.
applyDirect = function(events)
	if #events == 0 then return 0, {}, {} end

	-- Сначала родители, потом дети: при постепенном приёме объект не должен
	-- приезжать раньше того, во что его класть.
	table.sort(events, function(a, b)
		local ra, rb = a.rec or a, b.rec or b
		local da = (type(ra.anc) == "table") and #ra.anc or 0
		local db = (type(rb.anc) == "table") and #rb.anc or 0
		if da ~= db then return da < db end
		return (ra.op or a.op or "") < (rb.op or b.op or "")
	end)

	local recording = ChangeHistory:TryBeginRecording("RussTeam: приём всего проекта")
	local localSnap, index = Tree.scan()
	Apply.setBaseline(lastSnapshot)
	Apply.beginSession()   -- один список занятых на весь приём

	-- Порциями: Studio не подвисает, и видно, сколько осталось.
	local SLICE = Config.APPLY_SLICE
	local got, report = {}, { added = 0, adopted = 0, changed = 0,
		created = 0, removed = 0, skipped = 0 }
	local total = #events
	S.progress = { done = 0, total = total }

	local slice = {}
	for i = 1, total do
		table.insert(slice, events[i])
		if #slice >= SLICE or i == total then
			local partGot, partReport = Apply.applyEvents(slice, localSnap, index, "напарник")
			for _, c in ipairs(partGot or {}) do table.insert(got, c) end
			for k, v in pairs(partReport or {}) do
				report[k] = (report[k] or 0) + v
			end
			slice = {}
			S.progress.done = i
			S.statusText = string.format("принимаю: %d из %d — не трогай проект", i, total)
			pcall(Panel.refresh)
			task.wait()          -- отдаём управление Studio
		end
	end
	S.progress = nil

	-- Уборка сюда не входит: слишком легко снести чужую ветку.
	if recording then
		ChangeHistory:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
	end

	for _, c in ipairs(got) do
		local dup = false
		for _, have in ipairs(S.conflicts) do
			if have.sid == c.sid then dup = true break end
		end
		if not dup then table.insert(S.conflicts, c) end
	end
	while #S.conflicts > MAX_CONFLICTS do table.remove(S.conflicts, 1) end

	lastSnapshot = (Tree.scan())
	local applied = (report.added or 0) + (report.adopted or 0) + (report.changed or 0)
		+ (report.created or 0) + (report.removed or 0)
	return applied, got, report
end

--==============================================================
-- Один оборот обмена
--==============================================================

local function syncOnce(manual)
	if not RunService:IsEdit() then
		S.statusText = "подключен · идёт запуск игры, обмен на паузе"
		return
	end

	-- Нас просили прислать проект целиком — делаем это сейчас, в спокойный момент.
	if wantFullPush then
		wantFullPush = false
		-- Сначала убираем свои старые пачки с сервера: иначе они могут
		-- всплыть задним числом и наложиться поверх свежего снимка.
		local cleared = Net.post("/v1/reset", {
			channel = cfg.channel, me = participantId(), name = S.meName, scope = "mine",
		})
		if cleared and cleared.cleared and cleared.cleared > 0 then
			addHistory(string.format("убрал свои старые пачки: %d", cleared.cleared))
		end
		fullPushId = HttpService:GenerateGUID(false)
		lastSnapshot = {}
		addHistory("отправляю проект целиком по просьбе напарника")
	end

	local snap, _, count = Tree.scan()
	local events = Tree.diff(lastSnapshot, snap)
	S.myPending = #events

	-- Защита у источника: если МОЙ проект вдруг «потерял» кучу объектов,
	-- это почти всегда беда — сбой, откат, случайное удаление. Рассылать
	-- такое напарнику нельзя, пока человек не подтвердит.
	local myDels = 0
	for _, ev in ipairs(events) do
		if ev.op == "del" then myDels += 1 end
	end
	if myDels > Config.MAX_AUTO_DELETE and not sendDelApproved then
		S.sendPending = { count = myDels, total = #events }
		S.statusText = string.format(
			"у тебя исчезло %d объектов — не отправляю, подтверди внизу", myDels)
		addHistory(string.format("НЕ отправляю %d удалений — жду подтверждения", myDels))
		logError("в проекте исчезло %d объектов. Если ты этого не делал — "
			.. "нажми Ctrl+Z или прими проект напарника целиком", myDels)
		return
	end
	sendDelApproved = false
	S.sendPending = nil

	local since, hasAny = {}, false
	for k, v in pairs(cursors) do
		-- 'full' попадал сюда из-за старой поддельной пачки — это мусор
		if k ~= "full" then
			since[k] = v
			hasAny = true
		end
	end

	-- Родословная у соседних объектов одна и та же. Слать её в каждом событии
	-- значит удваивать объём — вместо этого шлём словарь на всю пачку,
	-- а в событии оставляем короткую ссылку.
	local chunkIndex, chunkTotal = 1, 1

	-- ВАЖНО: работаем на копиях. Записи в chunk — это те же таблицы, что лежат
	-- в снимке. Если стереть у них anc, то будущие события удаления окажутся
	-- без родословной, и удалять станет нечего: именно так пропадали удаления.
	local function packAncestry(chunk)
		if not chunk then return nil, nil end
		local dict, order = {}, {}
		local copies = table.create(#chunk)

		for i, ev in ipairs(chunk) do
			local src = ev.rec or ev
			local anc = src.anc
			local id = nil
			if type(anc) == "table" then
				local key = {}
				for _, e in ipairs(anc) do
					table.insert(key, (e.root or "") .. "/" .. (e.n or "") .. "/" .. (e.s or ""))
				end
				id = table.concat(key, ">")
				if not dict[id] then
					dict[id] = anc
					table.insert(order, id)
				end
			end

			-- копия записи без anc, но со ссылкой
			local recCopy = {}
			for k, v in pairs(src) do
				if k ~= "anc" then recCopy[k] = v end
			end
			if id then recCopy.ancRef = id end

			if ev.rec then
				local evCopy = {}
				for k, v in pairs(ev) do
					if k ~= "rec" then evCopy[k] = v end
				end
				evCopy.rec = recCopy
				copies[i] = evCopy
			else
				copies[i] = recCopy
			end
		end

		if #order == 0 then return copies, nil end
		return copies, dict
	end

	local function makeBody(chunk)
		local packed, ancs = packAncestry(chunk)
		return {
			ancs    = ancs,
			full    = fullPushId and { id = fullPushId, part = chunkIndex, total = chunkTotal } or nil,
			channel = cfg.channel,
			me      = participantId(),
			name    = S.meName,
			place   = tostring(game.PlaceId),
			ver     = VERSION,
			auto    = S.autoOn,
			edit    = true,
			pending = S.myPending,
			since   = hasAny and since or {},
			events  = packed,
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
		chunkTotal = #chunks
		addHistory(string.format("изменений много (%d) — отправляю %d порциями", #events, #chunks))
	elseif #events > 0 then
		chunks = { events }
	end

	local res, err
	if #chunks == 0 then
		res, err = Net.post("/v1/sync", makeBody(nil))
	else
		for i, chunk in ipairs(chunks) do
			chunkIndex = i
			res, err = Net.post("/v1/sync", makeBody(chunk))
			if err then break end
			if i < #chunks then task.wait(0.2) end
		end
	end
	if err then
		-- Сервер может отказать осмысленно: устаревшая версия или отключение.
		if err:find("устарела") then
			S.statusText = "обнови плагин · " .. err
			S.connected = false
			logError("%s", err)
			return
		end
		if err:find("отключили") then
			S.statusText = "тебя отключили от канала"
			S.connected = false
			addHistory("меня отключили от канала")
			return
		end
		S.statusText = "сбой обмена · " .. err
		tick = math.min(tick * 2, TICK_MAX)
		return
	end

	tick = AUTO_TICK
	S.roster = res.roster or S.roster
	notePresence(S.roster)

	-- Напарник попросил прислать проект целиком — откликаемся один раз.
	local ask = res.fullRequest
	if type(ask) == "table" and ask.at and honoredRequest ~= ask.at then
		honoredRequest = ask.at
		-- Отправку ставим в очередь, а не запускаем тут же: обмен сейчас занят
		-- самим собой, и запуск «если не занято» просто пропускался.
		wantFullPush = true
		addHistory(string.format("%s просит весь проект — отправлю следующим заходом",
			tostring(ask.name or ask.by)))
	end

	local sent = 0
	if res.n then
		fullPushId = nil
		lastSnapshot = snap
		S.myPending = 0
		sent = #events
		addHistory(string.format("отправлено %d", sent))
	end

	if Tree.wasTruncated() then
		logError("обход остановлен на %d объектах — часть проекта НЕ синхронизируется", MAX_INSTANCES)
		addHistory(string.format("проект больше %d объектов — часть не уходит!", MAX_INSTANCES))
	end

	local applied, got, report = applyBatches(res.batches or {})
	report = report or {}

	-- Пишем, что произошло на самом деле, а не сколько событий прислали.
	-- Раньше пропущенные считались принятыми — отсюда «принято», хотя ничего
	-- не изменилось.
	if applied > 0 or (report.skipped or 0) > 0 then
		local who = {}
		for _, b in ipairs(res.batches or {}) do who[b.authorName or "?"] = true end
		local names = {}
		for n in pairs(who) do table.insert(names, n) end

		local parts = {}
		if (report.added or 0) > 0 then table.insert(parts, string.format("создано %d", report.added)) end
		if (report.adopted or 0) > 0 then table.insert(parts, string.format("узнано своих %d", report.adopted)) end
		if (report.changed or 0) > 0 then table.insert(parts, string.format("изменено %d", report.changed)) end
		if (report.created or 0) > 0 then table.insert(parts, string.format("достроено %d", report.created)) end
		if (report.removed or 0) > 0 then table.insert(parts, string.format("удалено %d", report.removed)) end
		if (report.skipped or 0) > 0 then table.insert(parts, string.format("НЕ ПРИНЯТО %d", report.skipped)) end

		addHistory(string.format("от %s: %s", table.concat(names, ", "),
			#parts > 0 and table.concat(parts, ", ") or "ничего"))
	end

	-- Меши, которые не собрались, и ссылки, ждущие цель: и то и другое
	-- раньше пропадало молча.
	local meshFails = Apply.takeMeshFails()
	local nFails = 0
	for id, reason in pairs(meshFails) do
		nFails += 1
		if nFails <= 3 then
			addHistory(string.format("меш не собрался: %s", tostring(id):sub(1, 40)))
			logError("меш %s не собрался: %s", tostring(id), tostring(reason):sub(1, 80))
		end
	end
	if nFails > 0 then
		S.statusText = string.format("подключен · мешей не собралось: %d", nFails)
	end

	local waitingRefs = Apply.pendingRefCount()
	if waitingRefs > 0 then
		addHistory(string.format("ссылок ждут цели: %d", waitingRefs))
	end

	-- Запрет на скрипты проверяем ВСЕГДА, а не только когда что-то пришло:
	-- при отправке отказ на чтение так же смертелен, и человек должен узнать.
	local readDenied = Serialize.takeSourceReadDenied()
	local writeDenied = Apply.takeSourceDenied()
	if readDenied > 0 or writeDenied > 0 then
		S.scriptsBlocked = true
		if readDenied > 0 then
			addHistory(string.format("скрипты не отправлены (%d): нет разрешения", readDenied))
		end
		if writeDenied > 0 then
			addHistory(string.format("скрипты не приняты (%d): нет разрешения", writeDenied))
		end
		logError("скрипты не переносятся (не прочитано %d, не записано %d). "
			.. "Plugins → управление плагинами → RussTeam → разрешить изменение скриптов, "
			.. "затем перезапустить Studio", readDenied, writeDenied)
	end
	if #got > 0 then
		addHistory(string.format("конфликтов: %d", #got))
	end
	if (report.skipped or 0) > 0 then
		logError("не принято %d изменений — либо у напарника плагин старее 2.7, "
			.. "либо объектам негде лечь", report.skipped)
	end

	if res.dropped and res.dropped > 0 then
		logError("сервер выбросил %d непрочитанных пачек: не хватило места", res.dropped)
		addHistory(string.format("ВНИМАНИЕ: сервер выбросил %d пачек", res.dropped))
	end

	if S.bigPending then return end
	if res.more then
		S.statusText = "подключен · есть ещё, доберу следующим заходом"
	elseif applied > 0 or sent > 0 or (report.skipped or 0) > 0 then
		local skipped = report.skipped or 0
		S.statusText = string.format("подключен · принято %d%s, отправлено %d, объектов %d",
			applied,
			skipped > 0 and string.format(", НЕ ПРИНЯТО %d", skipped) or "",
			sent, count)
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

	local saved = plugin:GetSetting("cursors_" .. safeId(cfg.channel) .. "_" .. safeId(game.PlaceId))
	if saved then
		local okJson, tbl = pcall(function() return HttpService:JSONDecode(saved) end)
		cursors = (okJson and type(tbl) == "table") and tbl or {}
	else
		cursors = {}
	end

	-- Сразу проверяем доступ к коду: иначе человек узнает о запрете только
	-- после первого обмена, когда скрипты уже «не доехали».
	do
		local probe
		for _, root in ipairs({ "ServerScriptService", "ReplicatedStorage", "StarterPlayer" }) do
			local okSvc, svc = pcall(function() return game:GetService(root) end)
			if okSvc and svc then
				for _, d in ipairs(svc:GetDescendants()) do
					if d:IsA("LuaSourceContainer") then
						probe = d
						break
					end
				end
			end
			if probe then break end
		end
		if probe then
			local okRead = pcall(function() return probe.Source end)
			S.scriptsBlocked = not okRead
			if not okRead then
				logError("нет доступа к коду скриптов — они не будут переноситься. "
					.. "Plugins → Manage Plugins → RussTeam → разрешить изменение скриптов, "
					.. "затем перезапустить Studio")
				addHistory("скрипты заблокированы: нет разрешения")
			end
		end
	end

	lastSnapshot = (Tree.scan())
	S.connected = true
	plugin:SetSetting("wantConnected", true)
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
			-- Прощаемся с сервером, чтобы напарник увидел уход сразу,
			-- а не ждал, пока запись протухнет.
			local wasChannel = cfg.channel
			S.connected = false
			S.roster = {}
			knownIds = {}
			S.presenceNote = nil
			S.statusText = "не подключен · обмен остановлен"
			addHistory("отключился")
			-- Запоминаем решение: при следующем запуске сам не подключусь.
			plugin:SetSetting("wantConnected", false)
			Panel.refresh()
			task.spawn(function()
				pcall(function()
					Net.post("/v1/leave", {
						channel = wasChannel,
						me = participantId(),
						name = S.meName,
					})
				end)
			end)
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

	-- Пригодится, когда напарник только присоединился или канал почистили:
	-- обычная отправка шлёт лишь разницу, а ему нужна основа целиком.
	-- Отправка проекта целиком: получатель приведёт свой проект в точное
	-- соответствие, включая удаление лишнего. Поэтому пачки помечаются как
	-- части одного снимка — прибираться можно только когда пришло всё.
	onFullPush = function()
		if not S.connected then
			S.statusText = "не подключен · сначала подключись"
			Panel.refresh()
			return
		end
		guard(function()
			-- Чистим свою ленту, чтобы старые пачки не наложились поверх.
			local cleared, err = Net.post("/v1/reset", {
				channel = cfg.channel, me = participantId(), name = S.meName, scope = "mine",
			})
			if err then
				S.statusText = "не смог убрать старое · " .. err
				return
			end
			if cleared and cleared.cleared and cleared.cleared > 0 then
				addHistory(string.format("убрал свои старые пачки: %d", cleared.cleared))
			end
			fullPushId = HttpService:GenerateGUID(false)
			lastSnapshot = {}
			addHistory("отправляю проект целиком")
			syncOnce(true)
			fullPushId = nil
		end, "отправляю всё")
	end,

	-- Уборка в два нажатия: сначала показываем, что нашли, и только
	-- по второму нажатию удаляем. Вслепую тут удалять нельзя.
	onDedupe = function()
		guard(function()
			-- Список объектов протухает: за минуту проект мог измениться,
			-- и удалять по старому списку опасно.
			if dedupeReady and (os.time() - dedupeAt) > 60 then
				dedupeReady = false
				dedupeFound = nil
				S.statusText = "список устарел, ищу заново"
			end

			if not dedupeReady then
				local found = Apply.findDuplicates(Config.ROOTS)
				dedupeFound = found
				dedupeReady = #found > 0
				dedupeAt = os.time()
				if #found == 0 then
					S.statusText = "подключен · дубликатов не нашлось"
					addHistory("уборка: дубликатов нет")
					return
				end
				-- показываем первые несколько, чтобы человек понял, что уйдёт
				for i = 1, math.min(#found, 8) do
					addHistory("дубликат: " .. found[i].path)
				end
				S.statusText = string.format(
					"найдено дубликатов: %d — нажми «Убрать дубликаты» ещё раз, чтобы удалить", #found)
				return
			end

			local recording = ChangeHistory:TryBeginRecording("RussTeam: уборка дубликатов")
			local removed = 0
			for _, pair in ipairs(dedupeFound or {}) do
				if pair.drop and pair.drop.Parent then
					pcall(function() pair.drop.Parent = nil end)
					removed += 1
				end
			end
			if recording then
				ChangeHistory:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			end
			dedupeReady = false
			dedupeFound = nil
			lastSnapshot = (Tree.scan())
			addHistory(string.format("уборка: убрано %d", removed))
			S.statusText = string.format("подключен · убрано %d дубликатов, Ctrl+Z вернёт", removed)
		end, "ищу дубликаты")
	end,

	-- Отключить участника из канала: пропадёт из переклички и пять минут
	-- не сможет вернуться. Его лента остаётся — там может быть нужное.
	onKick = function(id, name)
		if not S.connected or not id then return end
		guard(function()
			local res, err = Net.post("/v1/kick", {
				channel = cfg.channel,
				me = participantId(),
				name = S.meName,
				target = tostring(id),
			})
			if err then
				S.statusText = "не отключил · " .. err
				return
			end
			S.roster[tostring(id)] = nil
			knownIds[tostring(id)] = nil
			addHistory(string.format("отключил из канала: %s", tostring(name or id)))
			S.statusText = string.format("подключен · %s отключён от канала", tostring(name or id))
		end, "отключаю")
	end,

	onRepairMeshes = function()
		guard(function()
			local recording = ChangeHistory:TryBeginRecording("RussTeam: починка мешей")
			local fixed, hopeless, total = Apply.repairMeshes(Config.ROOTS)
			if recording then
				ChangeHistory:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			end
			lastSnapshot = (Tree.scan())
			if total == 0 then
				S.statusText = "подключен · пустых мешей нет"
				addHistory("починка: пустых мешей нет")
				return
			end
			addHistory(string.format("починено мешей: %d из %d", fixed, total))
			for i = 1, math.min(#hopeless, 5) do
				addHistory("не нашёл образец: " .. hopeless[i])
			end
			S.statusText = string.format("подключен · починено мешей %d из %d%s",
				fixed, total,
				#hopeless > 0 and string.format(", без образца %d", #hopeless) or "")
		end, "чиню меши")
	end,

	-- Попросить напарника прислать проект целиком.
	onRequestFull = function()
		if not S.connected then
			S.statusText = "не подключен · сначала подключись"
			Panel.refresh()
			return
		end
		guard(function()
			local _, err = Net.post("/v1/request-full", {
				channel = cfg.channel, me = participantId(), name = S.meName,
			})
			if err then
				S.statusText = "не попросил · " .. err
				return
			end
			addHistory("попросил прислать проект целиком")
			S.statusText = "подключен · попросил напарника прислать всё, жду"
		end, "прошу прислать всё")
	end,

	-- Подтвердить приём всего проекта.
	onAcceptFull = function()
		if not S.fullPending then return end
		guard(function()
			local id = S.fullPending.id
			local box = incomingFull[id]
			if not box or #box.events == 0 then
				S.fullPending = nil
				incomingFull[id] = nil
				S.statusText = "снимок устарел — нажми «Запросить весь проект»"
				return
			end

			-- Применяем прямо из собранного снимка: поддельный пакет для этого
			-- заводил мусорный курсор и путал учёт.
			incomingFull[id] = nil
			S.fullPending = nil

			-- Запоминаем состав снимка: по нему можно потом осознанно убрать
			-- то, чего у напарника нет. Отдельной кнопкой, не здесь.
			local keepSids, keepPaths = {}, {}
			for _, ev in ipairs(box.events) do
				local rec = ev.rec or ev
				if rec.sid then keepSids[rec.sid] = true end
				if rec.anc and rec.name and rec.cls then
					local path = {}
					for _, e in ipairs(rec.anc) do
						table.insert(path, e.root or ((e.n or "") .. ":" .. (e.c or "")))
					end
					table.insert(path, rec.name .. ":" .. rec.cls)
					keepPaths[table.concat(path, "/")] = true
				end
			end
			lastFullKeep = { sids = keepSids, paths = keepPaths, at = os.time(),
				count = #box.events }

			local applied, got, report = applyDirect(box.events)
			addHistory(string.format("весь проект принят: %d изменений", applied))
			S.statusText = string.format("подключен · принят весь проект: %d изменений", applied)
		end, "принимаю весь проект")
	end,

	-- Убрать то, чего нет у напарника. Только по прямой просьбе, в два
	-- нажатия и со списком: раньше это делалось само и сносило целые ветки.
	onPrune = function()
		guard(function()
			if not lastFullKeep then
				S.statusText = "сначала прими весь проект — потом можно убрать лишнее"
				addHistory("уборка лишнего: сначала нужен полный снимок")
				return
			end
			if os.time() - lastFullKeep.at > 900 then
				lastFullKeep = nil
				pruneReady = false
				S.statusText = "снимок устарел — прими весь проект заново"
				return
			end

			if not pruneReady then
				local doomed = Apply.findMissing(Config.ROOTS,
					lastFullKeep.sids, lastFullKeep.paths)
				pruneFound = doomed
				pruneReady = #doomed > 0
				if #doomed == 0 then
					S.statusText = "подключен · лишнего нет"
					addHistory("уборка лишнего: нечего убирать")
					return
				end
				for i = 1, math.min(#doomed, 10) do
					addHistory("лишнее: " .. doomed[i].path)
				end
				S.statusText = string.format(
					"нашлось лишнего: %d — нажми ещё раз, чтобы убрать", #doomed)
				return
			end

			local recording = ChangeHistory:TryBeginRecording("RussTeam: уборка лишнего")
			local removed = 0
			for _, item in ipairs(pruneFound or {}) do
				if item.inst and item.inst.Parent then
					pcall(function() item.inst.Parent = nil end)
					removed += 1
				end
			end
			if recording then
				ChangeHistory:FinishRecording(recording, Enum.FinishRecordingOperation.Commit)
			end
			pruneReady = false
			pruneFound = nil
			lastSnapshot = (Tree.scan())
			addHistory(string.format("убрано лишнего: %d", removed))
			S.statusText = string.format("подключен · убрано %d, Ctrl+Z вернёт", removed)
		end, "ищу лишнее")
	end,

	-- Отказаться от полного снимка: он просто выбрасывается.
	onRejectFull = function()
		if not S.fullPending then return end
		local id = S.fullPending.id
		local count = S.fullPending.count or 0
		incomingFull[id] = nil
		S.fullPending = nil
		addHistory(string.format("отклонил весь проект: %d объектов", count))
		S.statusText = string.format("подключен · отклонено %d объектов, проект не тронут", count)
		Panel.refresh()
	end,

	-- Отказаться от большой пачки или от удалений.
	onRejectBig = function()
		if not S.bigPending then return end
		local count = S.bigPending.count or 0
		local dels = S.bigPending.deletions
		S.bigPending = nil
		addHistory(dels
			and string.format("отклонил удаление %d объектов", dels)
			or string.format("отклонил %d изменений", count))
		S.statusText = dels
			and string.format("подключен · удаление %d объектов отклонено", dels)
			or string.format("подключен · %d изменений отклонено", count)
		Panel.refresh()
	end,

	-- Отказаться отправлять свои удаления.
	onRejectSend = function()
		if not S.sendPending then return end
		local count = S.sendPending.count or 0
		S.sendPending = nil
		-- Точку отсчёта сдвигаем: считаем, что этих удалений не было.
		lastSnapshot = (Tree.scan())
		addHistory(string.format("не отправляю %d удалений", count))
		S.statusText = string.format("подключен · %d удалений не отправлено", count)
		Panel.refresh()
	end,

	-- Подтвердить отправку массовых удалений.
	onAcceptSend = function()
		if not S.sendPending then return end
		guard(function()
			sendDelApproved = true
			S.sendPending = nil
			addHistory("подтвердил отправку удалений")
			syncOnce(true)
		end, "отправляю")
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
			local events = S.bigPending.events
			S.bigPending = nil
			if not events or #events == 0 then
				S.statusText = "подключен · подтверждать нечего"
				return
			end
			local applied = applyDirect(events)
			addHistory(string.format("подтверждено вручную: принято %d", applied))
			S.statusText = string.format("подключен · принято %d изменений", applied)
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
	local wanted = plugin:GetSetting("wantConnected")
	if wanted == false then
		S.statusText = "не подключен · ты отключился сам, нажми «Подключиться»"
		Panel.refresh()
		return
	end
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
