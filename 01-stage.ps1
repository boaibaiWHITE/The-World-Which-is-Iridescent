# ============================================================================
# deploy\01-stage.ps1  --  取产物 -> 校验 -> 提交（不推送）
#
# 用法（在 D:\ai\deploy 下）：
#     .\01-stage.ps1                      # 用默认产物路径
#     .\01-stage.ps1 -Message "改了什么"   # 自定义提交信息
#
# 四步，任何一步失败就停。关键设计：先拷到暂存文件校验，通过了才覆盖
# index.html —— 这样校验失败时工作区不会被坏文件污染，仓库也不会有半成品提交。
#     1. 确认产物文件已稳定（防止拷贝到生成脚本正在写的半个文件）
#     2. 拷贝到 .index.staged
#     3. 对暂存文件跑 verify-site.js，全过才继续
#     4. 落到 index.html 并 git commit
#
# 注意：本文件保存为 UTF-8 with BOM。Windows PowerShell 5.1 对无 BOM 的
#       UTF-8 脚本会按 ANSI 解码，中文注释会被解坏并产生语法错误。
# ============================================================================

param(
    [string]$Source  = 'D:\ai\虹彩世界\产物\虹彩世界.html',
    [string]$Verifier = 'D:\ai\my-website\verify-site.js',
    [string]$Message = '',
    [int]$StabilityWaitSeconds = 8
)

$ErrorActionPreference = 'Stop'
$deployDir = $PSScriptRoot
$target    = Join-Path $deployDir 'index.html'
$staged    = Join-Path $deployDir '.index.staged'

function Fail($msg) {
    Write-Host ""
    Write-Host "  [失败] $msg" -ForegroundColor Red
    Write-Host "  已中止。deploy\index.html 未被改动，仓库也未被改动。" -ForegroundColor DarkGray
    exit 1
}

try {
    Write-Host ""
    Write-Host "=== 步骤 1/4  检查产物稳定性 ===" -ForegroundColor Cyan
    if (-not (Test-Path $Source)) { Fail "产物不存在：$Source" }
    $srcItem = Get-Item $Source
    Write-Host ("  产物     : {0}" -f $Source)
    Write-Host ("  大小     : {0} 字节" -f $srcItem.Length)
    Write-Host ("  修改时间 : {0}" -f $srcItem.LastWriteTime)

    # 生成脚本可能正在重写这个文件。隔几秒取两次哈希，不一致说明还在写。
    $h1 = (Get-FileHash $Source).Hash
    Write-Host ("  等 {0} 秒复测哈希…" -f $StabilityWaitSeconds) -ForegroundColor DarkGray
    Start-Sleep -Seconds $StabilityWaitSeconds
    $h2 = (Get-FileHash $Source).Hash
    if ($h1 -ne $h2) {
        Fail "产物在 $StabilityWaitSeconds 秒内被重新写入（哈希变化）。等生成脚本跑完再试。"
    }
    Write-Host ("  哈希     : {0}…  已稳定" -f $h2.Substring(0, 24)) -ForegroundColor Green

    Write-Host ""
    Write-Host "=== 步骤 2/4  拷贝到暂存文件（尚未覆盖 index.html）===" -ForegroundColor Cyan
    Copy-Item $Source $staged -Force
    if ((Get-FileHash $staged).Hash -ne $h2) { Fail "拷贝后的哈希与源不一致，拷贝过程可能出错。" }
    Write-Host ("  暂存     : .index.staged，{0} 字节，哈希与源一致" -f (Get-Item $staged).Length) -ForegroundColor Green

    Write-Host ""
    Write-Host "=== 步骤 3/4  结构校验（对暂存文件）===" -ForegroundColor Cyan
    if (-not (Test-Path $Verifier)) { Fail "校验器不存在：$Verifier" }
    $out = & node $Verifier $staged 2>&1 | Out-String
    $out.Trim() -split "`n" | ForEach-Object { "  " + $_.TrimEnd() }
    if ($out -notmatch '全部通过') {
        Fail "校验未全部通过，拒绝提交。产物可能被生成脚本写坏了。"
    }

    Write-Host ""
    Write-Host "=== 步骤 4/4  校验通过，落到 index.html 并提交 ===" -ForegroundColor Cyan
    Move-Item $staged $target -Force
    if ((Get-FileHash $target).Hash -ne $h2) { Fail "落盘后哈希不一致，请重试。" }
    Write-Host ("  index.html 已更新为 {0} 字节" -f (Get-Item $target).Length) -ForegroundColor Green

    Push-Location $deployDir
    try {
        git add index.html .gitattributes netlify.toml .gitignore 01-stage.ps1 02-push.ps1 2>&1 | Out-Null
        $pending = git diff --cached --name-only
        if (-not $pending) {
            Write-Host ""
            Write-Host "  [跳过] 内容与上次提交完全相同，无需新提交。" -ForegroundColor Yellow
            exit 0
        }
        if (-not $Message) {
            $size = (Get-Item $target).Length
            $Message = "更新产物 ($size bytes, $($h2.Substring(0,8)))"
        }
        git -c core.quotepath=false commit -m $Message 2>&1 | Select-Object -First 3 | ForEach-Object { "  $_" }

        Write-Host ""
        Write-Host "=== 完成 ===" -ForegroundColor Green
        Write-Host ("  提交     : {0}" -f (git log --oneline -1))
        Write-Host ("  哈希     : {0}" -f $h2)
        Write-Host ""
        Write-Host "  下一步   : 运行 .\02-push.ps1 推送到远端并触发部署" -ForegroundColor Cyan
        Write-Host ""
    } finally {
        Pop-Location
    }
} finally {
    # 无论成功失败都不留暂存文件
    if (Test-Path $staged) { Remove-Item $staged -Force -ErrorAction SilentlyContinue }
}
