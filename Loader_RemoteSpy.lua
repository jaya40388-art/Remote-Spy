--[[
    Loader untuk JAYA REMOTE SPY
    File ini di-host di GitHub dan di-load oleh script pendek
    Struktur: Loader_RemoteSpy.lua → load RemoteSpy.lua

    Script pendek untuk dijalankan di executor:
    loadstring(game:HttpGet("https://raw.githubusercontent.com/jaya40388-art/GrowAGarden-AutoBuy/refs/heads/main/Loader_RemoteSpy.lua"))()
]]

local HttpGet = game.HttpGet
local BASE_URL = "https://raw.githubusercontent.com/jaya40388-art/GrowAGarden-AutoBuy/refs/heads/main/"
local FILE_NAME = "RemoteSpy.lua"
local CACHE_BUST = true -- true = selalu ambil versi terbaru (GitHub raw biasa menyimpan cache ±5 menit)

local TAG = "[RemoteSpy Loader]"

-- Ambil script dari GitHub (dibungkus pcall supaya tidak crash jika internet / URL bermasalah)
local url = BASE_URL .. FILE_NAME
if CACHE_BUST then
    url = url .. "?t=" .. tostring(os.time())
end

local okGet, source = pcall(HttpGet, game, url)
if not okGet or type(source) ~= "string" or source == "" then
    warn(TAG .. " Gagal mengunduh " .. FILE_NAME .. " -> " .. tostring(source))
    return
end

-- GitHub membalas "404: Not Found" (teks biasa) jika file tidak ada / nama salah
if source:sub(1, 3) == "404" then
    warn(TAG .. " File tidak ditemukan di GitHub. Cek nama file & lokasinya: " .. url)
    return
end

-- Kompilasi script
local chunk, compileErr = loadstring(source)
if not chunk then
    warn(TAG .. " Script rusak / gagal dikompilasi: " .. tostring(compileErr))
    return
end

-- Jalankan script
local okRun, runErr = pcall(chunk)
if not okRun then
    warn(TAG .. " Error saat menjalankan script: " .. tostring(runErr))
end
