# ============================================================================
# deploy\02-push.ps1  --  推送 + 触发部署
#
# 用法（在 D:\ai\deploy 下）：
#     .\02-push.ps1
#
# 做的事：
#     1. 检查工作区是否干净、有没有未推送的提交
#     2. git push 到远端（如果配了 remote）
#     3. 如果配了 Netlify build hook，调用它触发部署
#
# ---------------------------------------------------------------------------
# 首次使用前，先把远端配好（二选一）：
#
#   【A】GitHub + Netlify 联动（推荐，push 后 Netlify 自动部署）
#        git remote add origin https://github.com/<你的用户名>/<仓库名>.git
#        git push -u origin main
#        然后在 Netlify: Site configuration -> Build & deploy -> Link repository
#        Build command 留空，Publish directory 填 /
#
#   【B】只用 Netlify CLI（不走 GitHub）
#        netlify login
#        netlify link          # 选 Link this directory to an existing site
#        netlify deploy --prod --dir .
#
# ---------------------------------------------------------------------------
# 可选：设置 Netlify build hook 后，本脚本能直接触发部署（B 方案用不上）
#     把它存进本目录的 .netlify-hook 文件（一行 URL），或在环境变量里设
#     NETLIFY_BUILD_HOOK。两种方式都相当于密码，别提交进仓库——
#     .gitignore 已默认忽略 .netlify-hook。
# ============================================================================

param(
    [switch]$SkipHook
)

$ErrorActionPreference = 'Stop'
$deployDir = $PSScriptRoot

function Fail($msg) {
    Write-Host ""
    Write-Host "  [失败] $msg" -ForegroundColor Red
    exit 1
}

Push-Location $deployDir
try {
    Write-Host ""
    Write-Host "=== 步骤 1/3  检查仓库状态 ===" -ForegroundColor Cyan

    $dirty = git status --porcelain
    if ($dirty) {
        Write-Host "  工作区有未提交的改动：" -ForegroundColor Yellow
        $dirty -split "`n" | Where-Object { $_ } | ForEach-Object { "    $_" }
        Fail "请先运行 .\01-stage.ps1 提交，或手动处理这些文件。"
    }
    Write-Host "  工作区干净" -ForegroundColor Green

    $hasRemote = git remote
    if (-not $hasRemote) {
        Write-Host ""
        Write-Host "  [提示] 还没有配置远端仓库，无法 push。" -ForegroundColor Yellow
        Write-Host "         先执行（把地址换成你自己的）：" -ForegroundColor Yellow
        Write-Host "           git remote add origin https://github.com/<用户名>/<仓库名>.git" -ForegroundColor White
        Write-Host "           git push -u origin main" -ForegroundColor White
        Write-Host ""
        Write-Host "         或者改用 Netlify CLI 部署：" -ForegroundColor Yellow
        Write-Host "           netlify deploy --prod --dir ." -ForegroundColor White
        exit 0
    }
    Write-Host ("  远端     : {0}" -f ($hasRemote -join ', '))

    $branch = git rev-parse --abbrev-ref HEAD
    $local  = git rev-parse HEAD
    Write-Host ("  分支     : {0}" -f $branch)
    Write-Host ("  当前提交 : {0}" -f (git log --oneline -1))

    Write-Host ""
    Write-Host "=== 步骤 2/3  推送到远端 ===" -ForegroundColor Cyan
    $upstream = git rev-parse --abbrev-ref "$branch@{upstream}" 2>$null
    if (-not $upstream) {
        Write-Host "  首次推送，设置上游分支…" -ForegroundColor DarkGray
        git push -u origin $branch 2>&1 | ForEach-Object { "  $_" }
    } else {
        $ahead = git rev-list --count "$upstream..HEAD"
        if ($ahead -eq 0) {
            Write-Host "  本地与远端一致，没有新提交需要推送。" -ForegroundColor Yellow
        } else {
            Write-Host ("  有 {0} 个提交待推送…" -f $ahead) -ForegroundColor DarkGray
            git push 2>&1 | ForEach-Object { "  $_" }
        }
    }
    if ($LASTEXITCODE -ne 0) { Fail "git push 失败，检查网络或凭据（可能需要 Personal Access Token）。" }

    Write-Host ""
    Write-Host "=== 步骤 3/3  触发部署 ===" -ForegroundColor Cyan
    if ($SkipHook) {
        Write-Host "  已用 -SkipHook 跳过。" -ForegroundColor DarkGray
        exit 0
    }

    # 找 build hook：环境变量优先，其次本目录的 .netlify-hook 文件
    $hook = $env:NETLIFY_BUILD_HOOK
    $hookFile = Join-Path $deployDir '.netlify-hook'
    if (-not $hook -and (Test-Path $hookFile)) {
        $hook = (Get-Content $hookFile -Raw).Trim()
    }

    if ($hook) {
        try {
            $resp = Invoke-WebRequest -Uri $hook -Method Post -UseBasicParsing -TimeoutSec 30
            Write-Host ("  build hook 已调用，HTTP {0}" -f $resp.StatusCode) -ForegroundColor Green
        } catch {
            Write-Host ("  build hook 调用失败：{0}" -f $_.Exception.Message) -ForegroundColor Red
            Write-Host "  （push 本身已成功，Netlify 的 Git 联动仍会自动部署）" -ForegroundColor DarkGray
        }
    } else {
        Write-Host "  未配置 build hook。" -ForegroundColor DarkGray
        Write-Host "  如果你在 Netlify 里做了 Git 仓库联动，push 已自动触发部署，无需额外操作。" -ForegroundColor DarkGray
        Write-Host "  否则请手动：netlify deploy --prod --dir ." -ForegroundColor DarkGray
    }

    Write-Host ""
    Write-Host "=== 完成 ===" -ForegroundColor Green
    Write-Host "  去 Netlify 的 Deploys 页面看进度，通常几十秒后线上生效。" -ForegroundColor Cyan
    Write-Host ""
} finally {
    Pop-Location
}
