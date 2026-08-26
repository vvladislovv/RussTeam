--!nonstrict
-- Обход дерева проекта и сравнение двух снимков.
-- Здесь решается, что вообще считать изменением.

local Config    = require(script.Parent.Config)
local Serialize = require(script.Parent.Serialize)

local SID_ATTR       = Config.SID_ATTR
local SYNCED_CLASSES = Config.SYNCED_CLASSES
local IGNORE_NAMES   = Config.IGNORE_NAMES
local IGNORE_PREFIX  = Config.IGNORE_PREFIX
local MAX_INSTANCES  = Config.MAX_INSTANCES
local ROOTS          = Config.ROOTS
local SKIP_CHARACTERS = Config.SKIP_CHARACTERS

local capture    = Serialize.capture
local hashRecord = Serialize.hashRecord
local newSid     = Serialize.newSid
local rootSid    = Serialize.rootSid

local Tree = {}

local truncated = false

local function scan()
	local snap, index = {}, {}
	local count = 0
	truncated = false

	-- Персонажи (всё, внутри чего есть Humanoid) появляются и исчезают сами
	-- при запуске игры. Их синхронизировать бессмысленно.
	local function isCharacter(inst)
		return inst:FindFirstChildOfClass("Humanoid") ~= nil
	end

	local function ignored(inst)
		if IGNORE_NAMES[inst.Name] then return true end
		for _, pref in ipairs(IGNORE_PREFIX) do
			if inst.Name:sub(1, #pref) == pref then return true end
		end
		return SKIP_CHARACTERS and isCharacter(inst)
	end

	-- ancestry накапливается по ходу спуска: короткие записи «имя + класс + номер»
	local function walk(inst, parentSid, ancestry)
		for _, child in ipairs(inst:GetChildren()) do
			if ignored(child) then
				continue
			end
			if SYNCED_CLASSES[child.ClassName] then
				if count >= MAX_INSTANCES then
					truncated = true
					return
				end
				count += 1
				-- Копирование в Studio (Ctrl+D) переносит и атрибуты, поэтому
				-- у копии тот же номер, что у оригинала. Такую копию надо
				-- пометить заново, иначе два объекта считаются одним.
				local existing = child:GetAttribute(SID_ATTR)
				if type(existing) == "string" and snap[existing] then
					child:SetAttribute(SID_ATTR, newSid())
				end
				local rec = capture(child, parentSid, ancestry)
				rec.hash = hashRecord(rec)
				snap[rec.sid] = rec
				index[rec.sid] = child

				-- родословная для детей: наша плюс мы сами
				local deeper = table.clone(ancestry)
				table.insert(deeper, { n = rec.name, c = rec.cls, s = rec.sid })
				walk(child, rec.sid, deeper)
			end
		end
	end

	for _, rootName in ipairs(ROOTS) do
		local ok, root = pcall(function() return game:GetService(rootName) end)
		if ok and root then
			-- в начале родословной сам сервис: с него получатель начнёт поиск
			walk(root, rootSid(rootName), { { root = rootName } })
		end
	end

	return snap, index, count
end

--==============================================================
-- Разница между снимками
--==============================================================

local function diff(oldSnap, newSnap)
	local events = {}

	for sid, rec in pairs(newSnap) do
		local prev = oldSnap[sid]
		if not prev then
			table.insert(events, { op = "add", rec = rec })
		elseif prev.hash ~= rec.hash then
			table.insert(events, { op = "set", rec = rec, base = prev.hash })
		end
	end

	for sid, prev in pairs(oldSnap) do
		if not newSnap[sid] then
			-- Кладём имя, класс и родословную: у напарника проект другой,
			-- по одному номеру он объект не найдёт.
			table.insert(events, {
				op = "del", sid = sid, name = prev.name, cls = prev.cls,
				anc = prev.anc, parent = prev.parent, base = prev.hash,
			})
		end
	end

	return events
end

--==============================================================
-- Применение чужих изменений
--==============================================================
Tree.scan = scan
Tree.diff = diff
Tree.wasTruncated = function() return truncated end

return Tree
