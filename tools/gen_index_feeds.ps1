<#
.SYNOPSIS
    生成半导体日报索引页 + RSS + JSON Feed
.DESCRIPTION
    扫描 docs/ 目录下所有 YYYY-MM-DD.html 报告，解析元数据，生成聚合索引页
.PARAMETER RepoDir
    仓库根目录 (包含 docs/ 子目录)
.PARAMETER Date
    可选，仅处理指定日期的报告 (格式 YYYY-MM-DD)
.EXAMPLE
    .\gen_index_feeds.ps1 -RepoDir "C:\Users\3070\semi-watcher-repo"
    .\gen_index_feeds.ps1 -RepoDir "C:\Users\3070\semi-watcher-repo" -Date "2025-01-15"
#>

param(
    [Parameter(Mandatory=$true)]
    [string]$RepoDir,

    [Parameter(Mandatory=$false)]
    [string]$Date
)

$ErrorActionPreference = "Stop"
$RepoDir = (Resolve-Path -LiteralPath $RepoDir).Path

# ========== 配置常量 ==========
$DocsDir = Join-Path $RepoDir "docs"
$IndexFile = Join-Path $RepoDir "index.html"
$RssFile = Join-Path $RepoDir "feed.xml"
$JsonFile = Join-Path $RepoDir "feed.json"
$BaseUrl = "https://howpy.github.io/semi-watcher/"

# 优先级映射
$PriorityMap = @{
    'fire'  = @{ Emoji = '🔥'; Label = '重大突破/新品'; Class = 'pill-fire' }
    'star'  = @{ Emoji = '⭐'; Label = '技术进展';     Class = 'pill-star' }
    'chart' = @{ Emoji = '📊'; Label = '市场/标准';     Class = 'pill-chart' }
    'doc'   = @{ Emoji = '📄'; Label = '论文/专利';     Class = 'pill-doc' }
}

# ========== 辅助函数 ==========
function Parse-ReportHtml {
    param([string]$FilePath)
    $content = Get-Content $FilePath -Raw -Encoding UTF8
    
    # 提取第一个 news-item 标题
    $titleMatch = [regex]::Match($content, '<h3 class="item-title">([^<]+)</h3>')
    $pageTitle = [regex]::Match($content, '<title>([^<]+)</title>')
    $title = if ($pageTitle.Success) { $pageTitle.Groups[1].Value } elseif ($titleMatch.Success) { $titleMatch.Groups[1].Value } else { "日报 $([IO.Path]::GetFileNameWithoutExtension($FilePath))" }
    
    # 统计优先级 badge
    $priorityCounts = @{ fire=0; star=0; chart=0; doc=0 }
    $matches = [regex]::Matches($content, 'class="priority-badge priority-(\w+)-badge"')
    foreach ($m in $matches) {
        $key = $m.Groups[1].Value.ToLower()
        if ($priorityCounts.ContainsKey($key)) { $priorityCounts[$key]++ }
    }
    
    # 生成优先级汇总字符串
    $prioritySummary = ''
    foreach ($key in 'fire','star','chart','doc') {
        if ($priorityCounts[$key] -gt 0) {
            $prioritySummary += "$($PriorityMap[$key].Emoji)$($priorityCounts[$key]) "
        }
    }
    $prioritySummary = $prioritySummary.Trim()
    if (-not $prioritySummary) { $prioritySummary = '—' }
    
    # 提取第一个摘要 (核心看点)
    $summaryMatch = [regex]::Match($content, '<p class="summary-text">([^<]+)</p>')
    $highlight = if ($summaryMatch.Success) { $summaryMatch.Groups[1].Value.Substring(0, [math]::Min(120, $summaryMatch.Groups[1].Value.Length)) + '...' } else { '查看详细资讯...' }
    
    $date = [regex]::Match([IO.Path]::GetFileNameWithoutExtension($FilePath), '\d{4}-\d{2}-\d{2}').Value
    
    return [pscustomobject]@{
        Date           = $date
        Title          = $title
        PriorityCounts = $priorityCounts
        PrioritySummary= $prioritySummary
        Highlight      = $highlight
        Filename       = if ([IO.Path]::GetDirectoryName($FilePath) -eq $DocsDir) { "docs/$([IO.Path]::GetFileName($FilePath))" } else { [IO.Path]::GetFileName($FilePath) }
        Url            = if ([IO.Path]::GetDirectoryName($FilePath) -eq $DocsDir) { "${BaseUrl}docs/$([IO.Path]::GetFileName($FilePath))" } else { "$BaseUrl$([IO.Path]::GetFileName($FilePath))" }
    }
}

# ========== 主流程 ==========
Write-Host "=== 生成索引页 + Feeds ===" -ForegroundColor Cyan
Write-Host "RepoDir: $RepoDir" -ForegroundColor Gray
Write-Host "DocsDir: $DocsDir" -ForegroundColor Gray

if (-not (Test-Path $DocsDir)) {
    Write-Error "docs 目录不存在: $DocsDir"
    exit 1
}

# 扫描报告文件
$reportFiles = @(Get-ChildItem $DocsDir -Filter "*.html" | Where-Object { $_.Name -match '^\d{4}-\d{2}-\d{2}\.html$' -and $_.Name -ne '2025-01-15.html' }) + @(Get-ChildItem $RepoDir -Filter "daily-*.html" | Where-Object { $_.Name -match '^daily-\d{4}-\d{2}-\d{2}.*\.html$' })
if ($Date) {
    $reportFiles = $reportFiles | Where-Object { $_.BaseName -match [regex]::Escape($Date) }
}
$reportFiles = $reportFiles | Sort-Object { [datetime]::ParseExact([regex]::Match($_.BaseName, '\d{4}-\d{2}-\d{2}').Value, 'yyyy-MM-dd', $null) } -Descending

Write-Host "发现 $($reportFiles.Count) 份报告" -ForegroundColor Green

# 解析所有报告
$reports = @()
foreach ($f in $reportFiles) {
    try {
        $reports += Parse-ReportHtml $f.FullName
    } catch {
        Write-Warning "解析失败 $($f.Name): $_"
    }
}

# ========== 生成 index.html ==========
$LastUpdated = Get-Date -Format "yyyy-MM-dd HH:mm"
$TotalReports = $reports.Count
$TotalItems = 0; foreach ($r in $reports) { foreach ($count in $r.PriorityCounts.Values) { $TotalItems += $count } }

$cardsHtml = ''
foreach ($r in $reports) {
    $badges = ''
    foreach ($key in 'fire','star','chart','doc') {
        if ($r.PriorityCounts[$key] -gt 0) {
            $pm = $PriorityMap[$key]
            $badges += "<span class='pill $($pm.Class)'>$($pm.Emoji)$($r.PriorityCounts[$key])</span> "
        }
    }
    if (-not $badges) { $badges = "<span class='pill'>—</span> " }
    
    $cardsHtml += @"
<article class="report-card">
    <div class="report-date">$($r.Date)</div>
    <h3 class="report-title"><a href="$($r.Filename)">$($r.Title)</a></h3>
    <div class="report-priority">$badges</div>
    <p class="report-highlight">$($r.Highlight)</p>
</article>
"@
}

$indexHtml = @"
<!DOCTYPE html>
<html lang="zh-CN">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>半导体行业每日资讯日报 - 索引</title>
    <meta name="description" content="半导体行业每日资讯日报聚合页 - 关注 X-ray检测/成像、半导体质控(QC/QA)、失效分析(FA)、先进封装检测、设备厂商动态">
    <link rel="preconnect" href="https://fonts.googleapis.com">
    <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
    <link href="https://fonts.googleapis.com/css2?family=Noto+Sans+SC:wght@300;400;500;700&display=swap" rel="stylesheet">
    <link rel="alternate" type="application/rss+xml" title="RSS Feed" href="feed.xml">
    <link rel="alternate" type="application/json" title="JSON Feed" href="feed.json">
    <style>
:root { --primary:#1F3A5F; --accent:#E86C00; --bg:#F8FAFC; --card:#FFF; --border:#E2E8F0; --text:#1E293B; --muted:#64748B; --fire:#DC2626; --star:#F59E0B; --chart:#0891B2; --doc:#7C3AED; --font:'Noto Sans SC',-apple-system,sans-serif; }
* { box-sizing:border-box; margin:0; padding:0; }
body { font-family:var(--font); background:var(--bg); color:var(--text); line-height:1.6; font-size:16px; }
a { color:var(--primary); text-decoration:none; } a:hover { color:var(--accent); }
.container { max-width:1000px; margin:0 auto; padding:2rem 1.5rem; }
.header { text-align:center; margin-bottom:2rem; padding-bottom:1.5rem; border-bottom:2px solid var(--border); }
.site-title { font-size:2.2rem; font-weight:700; color:var(--primary); margin-bottom:0.5rem; }
.site-subtitle { font-size:1.1rem; color:var(--muted); text-transform:uppercase; letter-spacing:0.05em; }
.badge { display:inline-flex; align-items:center; padding:4px 12px; border-radius:999px; font-weight:500; font-size:0.75rem; margin:0.25rem; }
.badge-source { background:var(--accent); color:#fff; }
.badge-update { background:var(--primary); color:#fff; }
.stats-bar { display:flex; flex-wrap:wrap; justify-content:center; gap:1rem; margin-top:1rem; font-size:0.9rem; color:var(--muted); }
.stat strong { color:var(--primary); }
.feed-link { color:var(--accent); font-weight:500; }
.reports-grid { display:grid; grid-template-columns:repeat(auto-fill,minmax(320px,1fr)); gap:1rem; }
.report-card { background:var(--bg); border:1px solid var(--border); border-radius:8px; padding:1.5rem; transition:box-shadow .2s, border-color .2s, transform .2s; }
.report-card:hover { box-shadow:0 4px 12px rgba(0,0,0,.1); border-color:var(--primary); transform:translateY(-2px); }
.report-date { font-weight:600; color:var(--primary); font-size:0.95rem; margin-bottom:0.5rem; }
.report-title { font-size:1rem; font-weight:600; margin-bottom:0.5rem; line-height:1.4; }
.report-title a { color:var(--text); }
.report-priority { display:flex; flex-wrap:wrap; gap:4px; margin-bottom:0.5rem; }
.pill { padding:2px 8px; border-radius:999px; font-size:0.7rem; font-weight:500; border:1px solid; }
.pill-fire { background:#FEF2F2; color:var(--fire); border-color:#FECACA; }
.pill-star { background:#FFFBEB; color:var(--star); border-color:#FDE68A; }
.pill-chart { background:#ECFEFF; color:var(--chart); border-color:#CFFAFE; }
.pill-doc { background:#F5F3FF; color:var(--doc); border-color:#E9D5FF; }
.report-highlight { font-size:0.85rem; color:var(--muted); line-height:1.5; }
.footer { text-align:center; margin-top:3rem; padding-top:1.5rem; border-top:1px solid var(--border); color:var(--muted); font-size:0.85rem; }
@media (max-width:768px) { .reports-grid { grid-template-columns:1fr; } .site-title { font-size:1.8rem; } .stats-bar { flex-direction:column; } }
    </style>
</head>
<body>
    <div class="container">
        <header class="header">
            <h1 class="site-title">半导体行业每日资讯日报</h1>
            <p class="site-subtitle">Semi Daily Intelligence Report</p>
            <div>
                <span class="badge badge-source">依据官方原文核验整理</span>
                <span class="badge badge-update">更新时间：$LastUpdated</span>
            </div>
            <div class="stats-bar">
                <span class="stat"><strong>$TotalReports</strong> 份报告</span>
                <span class="stat"><strong>$TotalItems</strong> 条资讯</span>
                <span class="stat"><a href="feed.xml" class="feed-link">RSS</a> | <a href="feed.json" class="feed-link">JSON Feed</a></span>
            </div>
        </header>
        <main>
            <section class="reports-section">
                <div class="reports-grid">
$cardsHtml
                </div>
            </section>
        </main>
        <footer class="footer">
            <p>© 2026 Semi-Watcher</p>
            <p><a href="https://github.com/howpy/semi-watcher" target="_blank" rel="noopener">GitHub 仓库</a> | <a href="https://github.com/howpy/semi-watcher/issues" target="_blank" rel="noopener">反馈</a></p>
        </footer>
    </div>
</body>
</html>
"@

$indexHtml | Set-Content $IndexFile -Encoding UTF8
Write-Host "✅ 已生成: index.html" -ForegroundColor Green

# ========== 生成 feed.xml (RSS 2.0) ==========
$rssItems = ''
foreach ($r in $reports | Select-Object -First 20) {
    $pubDate = ([datetime]::ParseExact($r.Date, 'yyyy-MM-dd', $null)).ToString("R")
    $rssItems += @"
    <item>
        <title><![CDATA[$($r.Title)]]></title>
        <link>$($r.Url)</link>
        <guid isPermaLink="true">$($r.Url)</guid>
        <pubDate>$pubDate</pubDate>
        <description><![CDATA[$($r.Highlight) $($r.PrioritySummary)]]></description>
        <category>$($r.PrioritySummary)</category>
    </item>
"@
}

$rss = @"
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">
<channel>
    <title>半导体行业每日资讯日报</title>
    <link>$BaseUrl</link>
    <description>关注 X-ray检测/成像、半导体质控(QC/QA)、失效分析(FA)、先进封装检测、设备厂商动态</description>
    <language>zh-CN</language>
    <lastBuildDate>$(Get-Date -Format "R")</lastBuildDate>
    <atom:link href="${BaseUrl}feed.xml" rel="self" type="application/rss+xml"/>
$rssItems
</channel>
</rss>
"@

$rss | Set-Content $RssFile -Encoding UTF8
Write-Host "✅ 已生成: feed.xml (RSS)" -ForegroundColor Green

# ========== 生成 feed.json (JSON Feed 1.1) ==========
$jsonItems = @()
foreach ($r in $reports | Select-Object -First 20) {
    $tags = @()
    foreach ($key in 'fire','star','chart','doc') {
        if ($r.PriorityCounts[$key] -gt 0) { $tags += $key }
    }
    $jsonItems += @{
        id              = $r.Url
        url             = $r.Url
        title           = $r.Title
        summary         = $r.Highlight
        date_published  = "$($r.Date)T00:00:00+08:00"
        tags            = $tags
        priority_summary= $r.PrioritySummary
    }
}

$jsonFeed = @{
    version        = "https://jsonfeed.org/version/1.1"
    title          = "半导体行业每日资讯日报"
    home_page_url  = $BaseUrl
    feed_url       = "${BaseUrl}feed.json"
    description    = "关注 X-ray检测/成像、半导体质控(QC/QA)、失效分析(FA)、先进封装检测、设备厂商动态"
    language       = "zh-CN"
    items          = $jsonItems
} | ConvertTo-Json -Depth 5 -Compress

$jsonFeed | Set-Content $JsonFile -Encoding UTF8
Write-Host "✅ 已生成: feed.json (JSON Feed)" -ForegroundColor Green

Write-Host "`n=== 完成 ===" -ForegroundColor Cyan
Write-Host "索引页: $IndexFile" -ForegroundColor Gray
Write-Host "RSS:    $RssFile" -ForegroundColor Gray
Write-Host "JSON:   $JsonFile" -ForegroundColor Gray