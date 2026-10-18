-- 本文件由 tools/build_lite.py 从 ../WeeklyBoard/Layout.lua 同步生成，请勿手改。
-- 改动请改源文件后重跑：python3 tools/build_lite.py
--[[--------------------------------------------------------------------------
    ForLeiJun / Layout.lua —— 三个窗口的布局配置

    ★ 这个文件由 tools/apply_layout.py 生成，**不要手改** ★
      改法：打开工作台（tools/layout_server.py，或双击 layout.command）
            → 顶部切「为了雷菌 / 路线追踪 / 拍卖查询」，改哪个窗就切哪个
            → 点「应用到插件」→ 游戏 /reload 生效。

    顶层键   = 置顶窗「路线追踪」（Pin.lua 渲染，full + lite 共用）
    ["main"] = 主窗「为了雷菌」四格大数 + 页签文案（LiteUI.lua 渲染，仅对外版）
    ["ah"]   = 置顶窗「拍卖查询」标题 / 占位符 / 空态说明（Pin.lua 渲染）

    这里只有「怎么摆 / 显示什么 / 写什么文案」。
    数字（站数、金币、百分比、快过期的任务）永远是游戏里实时算的 ——
    工作台里的示例数字不会被带进来，也不该被带进来。

    生成时间：2026-10-18 17:57:59
--------------------------------------------------------------------------]]--

local ADDON, ns = ...

ns.LAYOUT = {
    ["ah"] = {},
    ["main"] = {
        ["cols"] = 4,
        ["dragon"] = {
            ["goal"] = 500,
            ["title"] = "雷龙进度",
        },
        ["expire"] = {
            ["note"] = "都不着急",
            ["title"] = "6 小时内过期",
        },
        ["order"] = { "dragon", "trip", "take", "expire" },
        ["show"] = {
            ["dragon"] = true,
            ["expire"] = true,
            ["take"] = true,
            ["trip"] = true,
        },
        ["tabs"] = {
            ["ah"] = {
                ["label"] = "拍卖快照",
                ["sub"] = "没拍卖师也能查",
            },
            ["do"] = {
                ["label"] = "金币任务",
                ["sub"] = "本周哪些最值钱",
            },
        },
        ["take"] = {
            ["note"] = "任务实发，不含掉落",
            ["title"] = "这趟能拿",
        },
        ["trip"] = {
            ["sub"] = "按走法排好序",
            ["title"] = "这趟任务",
        },
    },
    ["maps"] = {
        ["bar"] = true,
        ["cols"] = 2,
        ["empty"] = true,
        ["eta"] = false,
        ["gold"] = true,
        ["order"] = {},
        ["sa"] = true,
        ["sort"] = "gold",
        ["stations"] = true,
    },
    ["ov"] = {},
    ["rev"] = 1792317479,
    ["sections"] = {
        {
            ["id"] = "total",
            ["on"] = true,
        },
        {
            ["id"] = "summary",
            ["on"] = true,
        },
        {
            ["id"] = "maps",
            ["on"] = true,
        },
        {
            ["id"] = "table",
            ["on"] = true,
        },
    },
    ["table"] = {
        ["coord"] = true,
        ["eta"] = true,
    },
    ["total"] = {
        ["gold"] = true,
        ["quests"] = true,
        ["sa"] = true,
        ["stations"] = true,
        ["weekly"] = false,
    },
    ["txt"] = {
        ["ah:hint"] = "输入物品名（中文/英文都行）或物品 ID，按回车查询。\n价格来自拍卖行浏览扫描：打开拍卖行会自动扫一次，也可以 /lj ah scan。",
    },
    ["winW"] = 620,
}
