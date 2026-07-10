@echo off
setlocal
set "PPTX=%~dpn0.pptx"
if not exist "%PPTX%" (
  echo Cannot find "%PPTX%"
  pause
  exit /b 1
)
set "NAV=%TEMP%\ppt_2level_navigator_%~n0.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:NAV; $c=[System.IO.File]::ReadAllText('%~f0'); $m=[regex]::Match($c,'(?s)__POWERSHELL__\r?\n(.*)$'); if(-not $m.Success){throw 'embedded script not found'}; [System.IO.File]::WriteAllText($p,$m.Groups[1].Value,[System.Text.Encoding]::ASCII)"
start "" powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File "%NAV%" -PptxPath "%PPTX%"
exit /b 0
__POWERSHELL__
param(
    [string]$PptxPath = "D:\Project\1V22\09.DesignReview\HV1V22_DesignReview_20260616_ORG.pptx"
)

$ErrorActionPreference = "Stop"

$pptxPath = [System.IO.Path]::GetFullPath($PptxPath)
$deckBaseName = [System.IO.Path]::GetFileNameWithoutExtension($pptxPath)
$deckPath = Join-Path $env:TEMP ($deckBaseName + "_live_deck.json")

if (!(Test-Path -LiteralPath $pptxPath)) { throw "Missing PPTX: $pptxPath" }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ppt = New-Object -ComObject PowerPoint.Application
$ppt.Visible = -1

$presentation = $null
try {
    foreach ($candidate in @($ppt.Presentations)) {
        try {
            if ($candidate.FullName -eq $pptxPath) {
                $presentation = $candidate
                break
            }
        } catch {}
    }
} catch {}

if ($presentation -eq $null) {
    $presentation = $ppt.Presentations.Open($pptxPath, 0, 0, -1)
}

function Get-CompactText([string[]]$texts) {
    $items = New-Object System.Collections.Generic.List[string]
    $seen = @{}
    foreach ($raw in $texts) {
        $item = (($raw -replace "\s+", " ").Trim())
        if ($item.Length -eq 0 -or $seen.ContainsKey($item)) { continue }
        $seen[$item] = $true
        $items.Add($item)
        if (($items -join " | ").Length -ge 110) { break }
    }
    $title = ($items -join " | ")
    if ($title.Length -gt 140) { $title = $title.Substring(0, 140) }
    if ($title.Length -eq 0) { $title = "Untitled slide" }
    return $title
}

function Get-SlideTitleFromCom($slide) {
    $candidates = New-Object System.Collections.Generic.List[object]
    foreach ($shape in @($slide.Shapes)) {
        try {
            if ($shape.HasTextFrame -and $shape.TextFrame.HasText) {
                $text = [string]$shape.TextFrame.TextRange.Text
                $flat = (($text -replace "\s+", " ").Trim())
                if ($flat.Length -gt 0) {
                    $fontSize = 0
                    try { $fontSize = [double]$shape.TextFrame.TextRange.Font.Size } catch {}
                    $candidates.Add([pscustomobject]@{
                        Text = $flat
                        Top = [double]$shape.Top
                        Left = [double]$shape.Left
                        FontSize = $fontSize
                    })
                }
            }
        } catch {}
    }

    $best = @($candidates |
        Where-Object {
            $_.Text.Length -gt 0 -and
            $_.Text.Length -le 180 -and
            $_.Top -lt 180 -and
            $_.Text -notmatch '^\d+$' -and
            $_.Text -notmatch '^(?i:updated?)$'
        } |
        Sort-Object @{ Expression = { -1 * $_.FontSize }; Ascending = $true },
                    @{ Expression = { $_.Top }; Ascending = $true },
                    @{ Expression = { $_.Left }; Ascending = $true } |
        Select-Object -First 1)

    if ($best.Count -gt 0) { return [string]$best[0].Text }
    return Get-CompactText (@($candidates | Sort-Object Top, Left | ForEach-Object { $_.Text }))
}

function Test-RedUpdateText($slide) {
    return [bool]((Get-RedUpdateDate $slide).HasRedUpdate)
}

function Get-RedUpdateDate($slide) {
    $result = [pscustomobject]@{
        HasRedUpdate = $false
        DateText = ""
    }
    foreach ($shape in @($slide.Shapes)) {
        try {
            if (!($shape.HasTextFrame -and $shape.TextFrame.HasText)) { continue }
            $range = $shape.TextFrame.TextRange
            $text = [string]$range.Text
            $updateMatches = [regex]::Matches($text, '(?i)updated?')
            if ($updateMatches.Count -eq 0) { continue }
            $dateText = ""
            $dateMatch = [regex]::Match($text, '(?i)updated?.{0,80}?(?<date>(?:20\d{2}[/-]\d{1,2}[/-]\d{1,2})|(?:20\d{6}))')
            if ($dateMatch.Success) { $dateText = $dateMatch.Groups['date'].Value }

            try {
                $rgb = [int]$range.Font.Color.RGB
                $r = $rgb -band 255
                $g = ($rgb -shr 8) -band 255
                $b = ($rgb -shr 16) -band 255
                if ($r -ge 180 -and $g -le 90 -and $b -le 90) {
                    $result.HasRedUpdate = $true
                    $result.DateText = $dateText
                    return $result
                }
            } catch {}

            foreach ($match in $updateMatches) {
                $start = $match.Index + 1
                $len = $match.Length
                $positions = @($start, ($start + [Math]::Max(0, $len - 1)))
                foreach ($pos in $positions) {
                    try {
                        $ch = $range.Characters($pos, 1)
                        $rgb = [int]$ch.Font.Color.RGB
                        $r = $rgb -band 255
                        $g = ($rgb -shr 8) -band 255
                        $b = ($rgb -shr 16) -band 255
                        if ($r -ge 180 -and $g -le 90 -and $b -le 90) {
                            $result.HasRedUpdate = $true
                            $result.DateText = $dateText
                            return $result
                        }
                    } catch {}
                }
            }
        } catch {}
    }
    return $result
}

function New-DeckFromPresentation($presentation, [string]$sourcePath) {
    $slides = New-Object System.Collections.Generic.List[object]
    $slideCount = [int]$presentation.Slides.Count
    if ($slideCount -le 0) { $slideCount = 1 }

    for ($i = 1; $i -le $slideCount; $i++) {
        $slideId = [string]$i
        $title = ("Slide {0:000}" -f $i)
        $hasRedUpdate = $false
        $updateDate = ""
        try {
            $slide = $presentation.Slides.Item($i)
            $slideId = [string]$slide.SlideID
            $title = Get-SlideTitleFromCom $slide
            $updateInfo = Get-RedUpdateDate $slide
            $hasRedUpdate = [bool]$updateInfo.HasRedUpdate
            $updateDate = [string]$updateInfo.DateText
            if ($hasRedUpdate) {
                if ($updateDate.Length -gt 0) {
                    $title = $title + " *update " + $updateDate
                } else {
                    $title = $title + " *"
                }
            }
        } catch {}
        $slides.Add([pscustomobject]@{
            num = $i
            id = $slideId
            title = $title
            hasRedUpdate = [bool]$hasRedUpdate
            updateDate = $updateDate
        })
    }

    $sections = New-Object System.Collections.Generic.List[object]
    try {
        $sectionCount = [int]$presentation.SectionProperties.Count
    } catch {
        $sectionCount = 0
    }

    if ($sectionCount -gt 0) {
        $rawSections = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -le $sectionCount; $i++) {
            try {
                $first = [int]$presentation.SectionProperties.FirstSlide($i)
                if ($first -lt 1) { $first = 1 }
                if ($first -gt $slideCount) { $first = $slideCount }
                $rawSections.Add([pscustomobject]@{
                    Name = [string]$presentation.SectionProperties.Name($i)
                    Start = $first
                })
            } catch {
                $rawSections.Add([pscustomobject]@{
                    Name = "Section $i"
                    Start = 1
                })
            }
        }

        $orderedSections = @($rawSections.ToArray() | Sort-Object Start)
        $firstStart = if ($orderedSections.Count -gt 0) { [int]$orderedSections[0].Start } else { 1 }
        if ($firstStart -gt 1) {
            $nums = @()
            for ($n = 1; $n -lt $firstStart; $n++) { $nums += $n }
            if ($nums.Count -gt 0) {
                $sections.Add([pscustomobject]@{
                    name = "Index"
                    start = [int]$nums[0]
                    end = [int]$nums[$nums.Count - 1]
                    count = [int]$nums.Count
                    slides = @($nums)
                })
            }
        }

        for ($i = 0; $i -lt $orderedSections.Count; $i++) {
            try {
                $start = [int]$orderedSections[$i].Start
                $nextStart = $slideCount + 1
                if ($i -lt ($orderedSections.Count - 1)) {
                    $nextStart = [int]$orderedSections[$i + 1].Start
                }
                $count = [Math]::Max(1, $nextStart - $start)
                $nums = @()
                for ($n = $start; $n -lt ($start + $count); $n++) {
                    if ($n -ge 1 -and $n -le $slideCount) { $nums += $n }
                }
                if ($nums.Count -gt 0) {
                    $sections.Add([pscustomobject]@{
                        name = [string]$orderedSections[$i].Name
                        start = [int]$nums[0]
                        end = [int]$nums[$nums.Count - 1]
                        count = [int]$nums.Count
                        slides = @($nums)
                    })
                }
            } catch {}
        }
    }

    if ($sections.Count -eq 0) {
        $allSlides = @()
        for ($i = 1; $i -le $slideCount; $i++) { $allSlides += $i }
        $sections.Add([pscustomobject]@{
            name = "All Slides"
            start = 1
            end = [int]$slideCount
            count = [int]$slideCount
            slides = @($allSlides)
        })
    }

    $covered = @{}
    foreach ($sec in @($sections.ToArray())) {
        foreach ($num in @($sec.slides)) { $covered[[int]$num] = $true }
    }

    $missingRuns = New-Object System.Collections.Generic.List[object]
    $run = @()
    for ($i = 1; $i -le $slideCount; $i++) {
        if (!$covered.ContainsKey($i)) {
            $run += $i
        } elseif ($run.Count -gt 0) {
            $missingRuns.Add(@($run))
            $run = @()
        }
    }
    if ($run.Count -gt 0) { $missingRuns.Add(@($run)) }

    if ($missingRuns.Count -gt 0) {
        foreach ($missing in @($missingRuns.ToArray())) {
            if ($missing.Count -gt 0) {
                $sections.Add([pscustomobject]@{
                    name = "Index"
                    start = [int]$missing[0]
                    end = [int]$missing[$missing.Count - 1]
                    count = [int]$missing.Count
                    slides = @($missing)
                })
            }
        }
    }

    $sortedSections = @($sections.ToArray() | Sort-Object start)

    return [pscustomobject]@{
        source = $sourcePath
        slides = $slides.ToArray()
        sections = $sortedSections
    }
}

$deck = $null

Start-Sleep -Milliseconds 800
try {
    if ($ppt.Windows.Count -gt 0) {
        $ppt.ActiveWindow.ViewType = 9
        $ppt.ActiveWindow.View.GotoSlide(1)
    }
} catch {}

$form = New-Object System.Windows.Forms.Form
$form.Text = "HV1V22 PPT 2-Level Navigator"
$form.Width = 430
$form.Height = 760
$form.StartPosition = "Manual"
$form.TopMost = $true
$form.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 9)
$script:isCollapsed = $false
$script:normalBounds = $null

$screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
$form.Left = [Math]::Max(0, $screen.Right - $form.Width - 24)
$form.Top = [Math]::Max(0, $screen.Top + 24)

$layout = New-Object System.Windows.Forms.TableLayoutPanel
$layout.Dock = "Fill"
$layout.ColumnCount = 1
$layout.RowCount = 3
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 82))) | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28))) | Out-Null
$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100))) | Out-Null
$form.Controls.Add($layout)

$topPanel = New-Object System.Windows.Forms.Panel
$topPanel.Dock = "Fill"
$topPanel.Padding = New-Object System.Windows.Forms.Padding(10, 8, 10, 8)

$title = New-Object System.Windows.Forms.Label
$title.Text = "2-Level Navigator - Normal View"
$title.Dock = "Fill"
$title.Height = 22
$title.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 10, [System.Drawing.FontStyle]::Bold)
$topPanel.Controls.Add($title)

$collapseButton = New-Object System.Windows.Forms.Button
$collapseButton.Text = "<<"
$collapseButton.Dock = "Right"
$collapseButton.Width = 44
$collapseButton.TabStop = $false
$topPanel.Controls.Add($collapseButton)

$reloadButton = New-Object System.Windows.Forms.Button
$reloadButton.Text = "Reload"
$reloadButton.Dock = "Right"
$reloadButton.Width = 68
$reloadButton.TabStop = $false
$topPanel.Controls.Add($reloadButton)

$search = New-Object System.Windows.Forms.TextBox
$search.Dock = "Bottom"
$search.Height = 24
$search.Text = ""
$topPanel.Controls.Add($search)

$status = New-Object System.Windows.Forms.Label
$status.Dock = "Bottom"
$status.Height = 28
$status.TextAlign = "MiddleLeft"
$status.Padding = New-Object System.Windows.Forms.Padding(10, 0, 0, 0)
$status.Text = "Click a section or slide to jump in PowerPoint Normal View. No slide show."
$layout.Controls.Add($topPanel, 0, 0)
$layout.Controls.Add($status, 0, 2)

$tree = New-Object System.Windows.Forms.TreeView
$tree.Dock = "Fill"
$tree.HideSelection = $false
$tree.ShowNodeToolTips = $true
$tree.FullRowSelect = $true
$tree.Font = New-Object System.Drawing.Font("Microsoft JhengHei UI", 9)
$layout.Controls.Add($tree, 0, 1)

function Get-SlideTitle([int]$num) {
    if ($deck -eq $null -or @($deck.slides).Count -lt $num) { return ("Slide {0:000}" -f $num) }
    return [string]$deck.slides[$num - 1].title
}

function Add-Nodes([string]$filter) {
    if ($deck -eq $null) {
        $status.Text = "Loading PowerPoint slides..."
        return
    }
    $tree.BeginUpdate()
    try {
        $tree.Nodes.Clear()
        $needle = $filter.Trim().ToLowerInvariant()
        foreach ($sec in @($deck.sections)) {
            $sectionName = [string]$sec.name
            $sectionMatches = $needle.Length -eq 0 -or $sectionName.ToLowerInvariant().Contains($needle)
            $sectionNode = New-Object System.Windows.Forms.TreeNode
            $sectionNode.Text = ("{0:000}-{1:000}  {2} ({3})" -f [int]$sec.start, [int]$sec.end, $sectionName, [int]$sec.count)
            $sectionNode.Tag = [pscustomobject]@{ Kind = "Section"; Slide = [int]$sec.start }
            $sectionNode.ToolTipText = $sectionName
            $sectionHasRedUpdate = $false

            $visibleChildren = 0
            foreach ($slideNumRaw in $sec.slides) {
                $slideNum = [int]$slideNumRaw
                $slideTitle = Get-SlideTitle $slideNum
                $slideMeta = $null
                if (@($deck.slides).Count -ge $slideNum) { $slideMeta = $deck.slides[$slideNum - 1] }
                $slideHasRedUpdate = $false
                try { $slideHasRedUpdate = [bool]$slideMeta.hasRedUpdate } catch {}
                if ($slideHasRedUpdate) { $sectionHasRedUpdate = $true }
                $slideMatches = $needle.Length -eq 0 -or $slideTitle.ToLowerInvariant().Contains($needle) -or ([string]$slideNum).Contains($needle)
                if ($sectionMatches -or $slideMatches) {
                    $child = New-Object System.Windows.Forms.TreeNode
                    $child.Text = ("{0:000}  {1}" -f $slideNum, $slideTitle)
                    $child.Tag = [pscustomobject]@{ Kind = "Slide"; Slide = $slideNum }
                    $child.ToolTipText = $slideTitle
                    if ($slideHasRedUpdate) {
                        $child.ForeColor = [System.Drawing.Color]::Red
                    }
                    [void]$sectionNode.Nodes.Add($child)
                    $visibleChildren++
                }
            }

            if ($sectionHasRedUpdate) {
                $sectionNode.ForeColor = [System.Drawing.Color]::Red
            }

            if ($sectionMatches -or $visibleChildren -gt 0) {
                [void]$tree.Nodes.Add($sectionNode)
                if ($needle.Length -gt 0 -or [int]$sec.start -eq 1) { $sectionNode.Expand() }
            }
        }
        $redCount = @($deck.slides | Where-Object { try { [bool]$_.hasRedUpdate } catch { $false } }).Count
        $status.Text = ("Loaded sections={0}, slides={1}, red updates={2}" -f @($deck.sections).Count, @($deck.slides).Count, $redCount)
        if ($tree.Nodes.Count -gt 0) {
            $tree.TopNode = $tree.Nodes[0]
        }
    } finally {
        $tree.EndUpdate()
    }
}

function Load-Deck {
    if ($script:isReloading) { return }
    $script:isReloading = $true
    $status.Text = "Refreshing navigation..."
    [System.Windows.Forms.Application]::DoEvents()

    $loaded = $null
    $loaded = New-DeckFromPresentation $presentation $pptxPath

    $script:deck = $loaded
    Add-Nodes $search.Text
    try { $script:lastWriteUtc = (Get-Item -LiteralPath $pptxPath).LastWriteTimeUtc } catch {}
    $script:isReloading = $false
}

function Set-Collapsed([bool]$collapsed) {
    if ($collapsed -eq $script:isCollapsed) { return }
    if ($collapsed) {
        $script:normalBounds = $form.Bounds
        $tree.Visible = $false
        $search.Visible = $false
        $status.Visible = $false
        $title.Visible = $false
        $reloadButton.Visible = $false
        $collapseButton.Text = ">>"
        $form.Width = 58
        $form.Height = 120
        $form.Left = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea.Right - $form.Width - 8
        $form.Top = [Math]::Max(0, $form.Top)
    } else {
        $tree.Visible = $true
        $search.Visible = $true
        $status.Visible = $true
        $title.Visible = $true
        $reloadButton.Visible = $true
        $collapseButton.Text = "<<"
        if ($script:normalBounds -ne $null) {
            $form.Bounds = $script:normalBounds
        } else {
            $form.Width = 430
            $form.Height = 760
        }
    }
    $script:isCollapsed = $collapsed
}

function Go-ToSlide([int]$slideNum) {
    try {
        if ($ppt.Windows.Count -eq 0) {
            $presentation.NewWindow() | Out-Null
            Start-Sleep -Milliseconds 400
        }
        $ppt.ActiveWindow.ViewType = 9
        $ppt.ActiveWindow.View.GotoSlide($slideNum)
        $status.Text = ("Slide {0}: {1}" -f $slideNum, (Get-SlideTitle $slideNum))
    } catch {
        $status.Text = "Jump failed: " + $_.Exception.Message
    }
}

$tree.add_AfterSelect({
    param($sender, $eventArgs)
    if ($eventArgs.Node -and $eventArgs.Node.Tag) {
        Go-ToSlide ([int]$eventArgs.Node.Tag.Slide)
    }
})

$tree.add_NodeMouseDoubleClick({
    param($sender, $eventArgs)
    if ($eventArgs.Node.Nodes.Count -gt 0) {
        if ($eventArgs.Node.IsExpanded) { $eventArgs.Node.Collapse() } else { $eventArgs.Node.Expand() }
    }
})

$search.add_TextChanged({
    Add-Nodes $search.Text
})

$collapseButton.add_Click({
    Set-Collapsed (-not $script:isCollapsed)
})

$reloadButton.add_Click({
    Load-Deck
})

$form.add_FormClosed({
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($ppt) | Out-Null } catch {}
})

$form.add_Shown({
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
})

$script:loadAttempts = 0
$loadTimer = New-Object System.Windows.Forms.Timer
$loadTimer.Interval = 1000
$loadTimer.add_Tick({
    $script:loadAttempts++
    $slideCount = 0
    try { $slideCount = [int]$presentation.Slides.Count } catch { $slideCount = 0 }
    $status.Text = ("Loading PowerPoint slides... current count={0}, wait={1}s" -f $slideCount, $script:loadAttempts)
    if ($slideCount -gt 1 -or $script:loadAttempts -ge 12) {
        $loadTimer.Stop()
        Load-Deck
    }
})

$form.add_Shown({
    $loadTimer.Start()
})

$script:lastWriteUtc = $null
try { $script:lastWriteUtc = (Get-Item -LiteralPath $pptxPath).LastWriteTimeUtc } catch {}
$script:isReloading = $false
$script:pendingReloadTicks = 0

$watchTimer = New-Object System.Windows.Forms.Timer
$watchTimer.Interval = 3000
$watchTimer.add_Tick({
    try {
        $currentWriteUtc = (Get-Item -LiteralPath $pptxPath).LastWriteTimeUtc
        if ($script:lastWriteUtc -ne $null -and $currentWriteUtc -ne $script:lastWriteUtc) {
            $script:lastWriteUtc = $currentWriteUtc
            $script:pendingReloadTicks = 2
            $status.Text = "PPT saved. Refreshing soon..."
        }

        if ($script:pendingReloadTicks -gt 0) {
            $script:pendingReloadTicks--
            if ($script:pendingReloadTicks -eq 0) {
                Load-Deck
            }
        }
    } catch {
        $status.Text = "Save watch failed: " + $_.Exception.Message
    }
})

$form.add_Shown({
    $watchTimer.Start()
})

Add-Nodes ""
[void]$form.ShowDialog()

