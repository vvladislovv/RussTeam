--!nonstrict
-- Разговор с сервером. Единственное место, которое знает про HTTP.

local HttpService = game:GetService("HttpService")
local Config = require(script.Parent.Config)

local MAX_FEED_CHAR = Config.MAX_FEED_CHAR

local Net = {}

-- Адрес и ключ приходят снаружи: модуль их только использует.
local cfg = { server = "", key = "" }

function Net.configure(server, key)
	cfg.server = server or ""
	cfg.key = key or ""
end

local function serverUrl(path)
	local base = cfg.server
	if not base:match("^https?://") then base = "http://" .. base end
	base = base:gsub("/+$", "")
	return base .. path
end

-- Общий разбор ответа. Возвращает: тело, текст ошибки.
local function talk(method, path, body)
	local headers = { ["x-russteam-key"] = cfg.key }
	if body then headers["Content-Type"] = "application/json" end
	local ok, res = pcall(function()
		return HttpService:RequestAsync({
			Url = serverUrl(path),
			Method = method,
			Headers = headers,
			Body = body,
		})
	end)
	if not ok then
		return nil, "сервер недоступен: " .. tostring(res):sub(1, 120)
	end
	if res.StatusCode == 0 then
		return nil, "сервер не ответил"
	end
	local okJson, parsed = pcall(function() return HttpService:JSONDecode(res.Body) end)
	if not okJson then
		local text = tostring(res.Body)
		-- Веб-страница вместо ответа почти всегда значит «адрес ведёт не туда».
		if text:sub(1, 1) == "<" then
			return nil, string.format("по адресу отвечает веб-страница, а не RussTeam (код %d). "
				.. "Проверь адрес и порт", res.StatusCode)
		end
		return nil, string.format("ответ %d, не разобрал: %s", res.StatusCode, text:sub(1, 100))
	end
	if res.StatusCode == 401 then
		return nil, "сервер не принял ключ доступа"
	end
	if res.StatusCode == 429 then
		return nil, "слишком частые запросы, подожди минуту"
	end
	if res.StatusCode ~= 200 or parsed.ok == false then
		return nil, tostring(parsed.error or ("ответ " .. res.StatusCode))
	end
	return parsed, nil
end

local function post(path, tbl)
	local okEnc, body = pcall(function() return HttpService:JSONEncode(tbl) end)
	if not okEnc then return nil, "не собрал запрос" end
	if #body > MAX_FEED_CHAR then
		return nil, string.format("слишком много за раз (%.1f МБ). Отправляй чаще", #body / 1048576)
	end
	return talk("POST", path, body)
end

--==============================================================
-- Кто в канале
--==============================================================

Net.talk = talk
Net.post = post

return Net
