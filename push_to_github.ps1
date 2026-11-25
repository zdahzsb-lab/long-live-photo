param(
    [Parameter(Mandatory = $true, HelpMessage = "请输入你在 GitHub 新建的空仓库地址，例如 https://github.com/你的用户名/long-live-photo.git")]
    [string]$RepoUrl
)

$ErrorActionPreference = 'Stop'
$gitExe = "E:\Tools\git\cmd\git.exe"
if (-not (Test-Path $gitExe)) {
    $gitExe = "git"
}

Set-Location $PSScriptRoot

$existingRemote = & $gitExe remote
if ($existingRemote -contains "origin") {
    & $gitExe remote set-url origin $RepoUrl
} else {
    & $gitExe remote add origin $RepoUrl
}

Write-Host "正在推送代码到 $RepoUrl (分支: main)..." -ForegroundColor Cyan
& $gitExe branch -M main
& $gitExe push -u origin main

Write-Host "`n推送成功！请打开你的 GitHub 仓库页面 -> 点击顶部【Actions】标签页，等待约 5~8 分钟即可在底部 Artifacts 下载安卓 APK 与苹果 IPA 安装包。" -ForegroundColor Green
