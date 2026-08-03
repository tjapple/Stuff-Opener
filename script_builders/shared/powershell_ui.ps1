function Initialize-UiState {
    $script:UiStepNumber = 0
    $script:UiStepResults = New-Object System.Collections.ArrayList
    $script:UiActionLog = New-Object System.Collections.ArrayList
    $script:UiWidth = 120
    $script:RunContext = [ordered]@{
        StartedAt = Get-Date
    }

    $dryRunVariable = Get-Variable -Name DryRun -Scope Script -ErrorAction SilentlyContinue
    if ($dryRunVariable) {
        $script:RunContext["DryRun"] = [bool]$dryRunVariable.Value
    }

    $targetLookupVariable = Get-Variable -Name UserLookup -Scope Script -ErrorAction SilentlyContinue
    if ($targetLookupVariable) {
        $script:RunContext["TargetLookup"] = $targetLookupVariable.Value
    }

    $clientVariable = Get-Variable -Name Client -Scope Script -ErrorAction SilentlyContinue
    if ($clientVariable) {
        $script:RunContext["Client"] = $clientVariable.Value
    }

    $ticketVariable = Get-Variable -Name TicketNumber -Scope Script -ErrorAction SilentlyContinue
    if ($ticketVariable) {
        $script:RunContext["TicketNumber"] = $ticketVariable.Value
    }
}

function Test-UiDryRun {
    $dryRunVariable = Get-Variable -Name DryRun -Scope Script -ErrorAction SilentlyContinue
    return ($dryRunVariable -and [bool]$dryRunVariable.Value)
}

function Write-UiBanner {
    Clear-Host

    $banner = @(
        "+------------------------------------------------------------+",
        "|                                                            |",
        "|   ___ _____       ____  ____  ___ __     __ _____ ____     |",
        "|  |_ _|_   _|     |  _ \|  _ \|_ _|\ \   / /| ____|  _ \    |",
        "|   | |  | | _____ | | | | |_) || |  \ \ / / |  _| | |_) |   |",
        "|   | |  | ||_____|| |_| |  _ < | |   \ V /  | |___|  _ <    |",
        "|  |___| |_|       |____/|_| \_\___|   \_/   |_____|_| \_\   |",
        "|                                                            |",
        "+------------------------------------------------------------+"
    )

    $taglines = @(
        "Technician workflow runner",
        "Please keep hands and feet inside the PowerShell at all times",
        "Too sophisticated for a GUI"
    )

    Write-Host ""
    foreach ($line in $banner) {
        Write-Host $line -ForegroundColor Cyan
    }

    $tagline = Get-Random $taglines

    Write-Host "  $tagline" -ForegroundColor DarkCyan
    Write-Host "  Interactive AD / M365 automation helper" -ForegroundColor DarkGray
    Write-Host ""
    Wait-UiBeat
}

function Write-UiDivider {
    param(
        [string]$Character = "-"
    )

    $width = if ($script:UiWidth) { $script:UiWidth } else { 120 }
    Write-Host ($Character * $width) -ForegroundColor DarkGray
}

function Write-UiHeader {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Subtitle = ""
    )

    Write-Host ""
    Write-Host ""
    Write-Host ""
    Write-UiDivider -Character "="
    Write-UiDivider -Character "="
    Write-UiDivider -Character "="
    Write-Host ("  {0}" -f $Title.ToUpperInvariant()) -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($Subtitle)) {
        Write-Host ("  {0}" -f $Subtitle) -ForegroundColor Gray
    }
    Write-UiDivider -Character "="
}

function Write-UiSection {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Host ""
    Write-Host (">> {0}" -f $Title) -ForegroundColor Cyan
    Write-UiDivider
}

function Write-UiStatus {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ConsoleColor]$Color = "Gray"
    )

    Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $Color
}

function Write-UiKeyValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [AllowNull()]
        $Value
    )

    $valueText = [string]$Value
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace($valueText)) {
        $valueText = "(blank)"
    }

    Write-Host ("  {0,-28} {1}" -f ($Label + ":"), $valueText)
}

function Write-UiList {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [AllowNull()]
        [object[]]$Values
    )

    $items = @($Values | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($items.Count -eq 0) {
        Write-UiKeyValue -Label $Label -Value "None"
        return
    }

    Write-Host ("  {0}" -f ($Label + ":"))
    foreach ($item in $items) {
        Write-Host ("    - {0}" -f $item)
    }
}

function Read-UiInput {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string[]]$Options = @(),

        [string]$Suffix = ">:"
    )

    $promptText = if ([string]::IsNullOrWhiteSpace($Prompt)) { "" } else { $Prompt.Trim() }
    $cleanOptions = @($Options | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($cleanOptions.Count -gt 0) {
        if (-not [string]::IsNullOrWhiteSpace($promptText)) {
            Write-Host ("  {0}" -f $promptText) -ForegroundColor Magenta
        }

        Write-Host -NoNewline ("    {0} {1} " -f ($cleanOptions -join " / "), $Suffix) -ForegroundColor Magenta
    }
    else {
        Write-Host -NoNewline ("  {0} {1} " -f $promptText, $Suffix) -ForegroundColor Magenta
    }
    $answer = $Host.UI.ReadLine()
    if ($null -eq $answer) {
        return ""
    }

    return $answer
}

function Read-UiYesNo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [bool]$DefaultYes = $false
    )

    $suffix = if ($DefaultYes) { "[Y/n]" } else { "[y/N]" }

    while ($true) {
        $answer = Read-UiInput -Prompt $Prompt -Options @($suffix)

        if ([string]::IsNullOrWhiteSpace($answer)) {
            return $DefaultYes
        }

        switch -Regex ($answer.Trim()) {
            "^(y|yes)$" { return $true }
            "^(n|no)$"  { return $false }
            default {
                Write-UiStatus -Status "WARN" -Message "Please enter yes or no." -Color Yellow
            }
        }
    }
}

function Add-UiStepResult {
    param(
        [int]$StepNumber = $script:UiStepNumber,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$Result,

        [string]$Note = "",

        [string]$CommandPreview = ""
    )

    try {
        if ($null -eq $script:UiStepResults -or -not ($script:UiStepResults -is [System.Collections.ArrayList])) {
            $existingResults = @($script:UiStepResults | Where-Object { $_ })
            $script:UiStepResults = New-Object System.Collections.ArrayList
            foreach ($existingResult in $existingResults) {
                [void]$script:UiStepResults.Add($existingResult)
            }
        }

        [void]$script:UiStepResults.Add([pscustomobject]@{
            Step    = $StepNumber
            Result  = $Result
            Name    = $Name
            Note    = $Note
            Time    = (Get-Date).ToString("HH:mm:ss")
            Command = $CommandPreview
        })
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not record step summary entry: $($_.Exception.Message)" -Color Yellow
    }
}

function Add-UiActionLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [string]$CommandPreview,

        [ValidateSet("Completed", "Dry run")]
        [string]$Result = "Completed",

        [string]$Note = ""
    )

    if ([string]::IsNullOrWhiteSpace($CommandPreview)) {
        return
    }

    try {
        if ($null -eq $script:UiActionLog -or -not ($script:UiActionLog -is [System.Collections.ArrayList])) {
            $existingResults = @($script:UiActionLog | Where-Object { $_ })
            $script:UiActionLog = New-Object System.Collections.ArrayList
            foreach ($existingResult in $existingResults) {
                [void]$script:UiActionLog.Add($existingResult)
            }
        }

        [void]$script:UiActionLog.Add([pscustomobject]@{
            Time    = (Get-Date).ToString("HH:mm:ss")
            Result  = $Result
            Name    = $Name
            Command = $CommandPreview
            Note    = $Note
        })
    }
    catch {
        Write-UiStatus -Status "WARN" -Message "Could not record action log entry: $($_.Exception.Message)" -Color Yellow
    }
}

function Write-UiDryRunCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$CommandPreview = ""
    )

    Write-UiStatus -Status "...DRY RUN" -Message "Would have executed: $Name" -Color DarkGray
    if (-not [string]::IsNullOrWhiteSpace($CommandPreview)) {
        foreach ($line in ($CommandPreview -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Host ("  PS> {0}" -f $line) -ForegroundColor DarkGray
            }
        }
    }
}

function Invoke-UiCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [scriptblock]$Command,

        [string]$CommandPreview = "",

        [switch]$PassThru
    )

    if (Test-UiDryRun) {
        Write-UiDryRunCommand -Name $Name -CommandPreview $CommandPreview
        Add-UiActionLog -Name $Name -CommandPreview $CommandPreview -Result "Dry run" -Note "No command was executed."
        return $null
    }

    $result = & $Command
    Add-UiActionLog -Name $Name -CommandPreview $CommandPreview -Result "Completed"
    if ($PassThru) {
        return $result
    }
}

function Write-UiStepSummary {
    if ($script:UiStepResults.Count -eq 0) {
        return
    }

    $summaryLines = @(
        "{0,-4} {1,-10} {2,-28} {3}" -f "Step", "Result", "Name", "Time"
        "{0,-4} {1,-10} {2,-28} {3}" -f "----", "------", "----", "----"
    )

    foreach ($result in $script:UiStepResults) {
        $summaryLines += "{0,-4} {1,-10} {2,-28} {3}" -f $result.Step, $result.Result, $result.Name, $result.Time
    }

    Write-UiBox -Title "Step Summary" -Lines $summaryLines
}

function Write-UiActionLog {
    if ($null -eq $script:UiActionLog -or $script:UiActionLog.Count -eq 0) {
        return
    }

    $lines = @()
    $logWidth = if ($script:UiWidth) { [int]$script:UiWidth } else { 120 }
    $maxLineLength = [Math]::Max(40, $logWidth - 12)
    function Add-ActionLogLine {
        param(
            [Parameter(Mandatory = $true)]
            [string]$Text
        )

        $remaining = $Text
        while ($remaining.Length -gt $maxLineLength) {
            $breakAt = $remaining.LastIndexOf(" ", [Math]::Min($maxLineLength, $remaining.Length - 1))
            if ($breakAt -lt 20) {
                $breakAt = $maxLineLength
            }

            $script:__UiActionLogWrappedLines += $remaining.Substring(0, $breakAt).TrimEnd()
            $remaining = "   " + $remaining.Substring($breakAt).TrimStart()
        }

        $script:__UiActionLogWrappedLines += $remaining
    }

    $script:__UiActionLogWrappedLines = @()
    $index = 0
    foreach ($entry in @($script:UiActionLog | Where-Object { $_ })) {
        $index++
        Add-ActionLogLine -Text ("{0}. [{1}] {2} ({3})" -f $index, $entry.Result, $entry.Name, $entry.Time)
        foreach ($line in ([string]$entry.Command -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Add-ActionLogLine -Text "   PS> $line"
            }
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$entry.Note)) {
            Add-ActionLogLine -Text "   Note: $($entry.Note)"
        }
    }

    $lines = @($script:__UiActionLogWrappedLines)
    Remove-Variable -Name __UiActionLogWrappedLines -Scope Script -ErrorAction SilentlyContinue
    Write-UiBox -Title "Action Log" -Lines $lines
}

function Write-UiFinalRunSummary {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [string]$Subtitle = "",

        [string]$ErrorMessage = ""
    )

    Write-UiHeader -Title $Title -Subtitle $Subtitle
    if (-not [string]::IsNullOrWhiteSpace($ErrorMessage)) {
        Write-UiStatus -Status "FAIL" -Message $ErrorMessage -Color Red
    }

    Write-UiStepSummary
    Write-UiActionLog
}

function Write-UiStepDetails {
    param(
        [string]$CommandPreview = ""
    )

    Write-Host ""
    Write-Host "  Command Preview" -ForegroundColor Blue
    Write-Host "  ---------------" -ForegroundColor DarkGray

    if ([string]::IsNullOrWhiteSpace($CommandPreview)) {
        Write-Host "  No command preview was provided for this step." -ForegroundColor DarkGray
        return
    }

    foreach ($line in ($CommandPreview -split "`r?`n")) {
        Write-Host ("  PS> {0}" -f $line) -ForegroundColor Gray
    }
}

function ConvertTo-PowerShellSingleQuotedString {
    param(
        [AllowNull()]
        $Value
    )

    return "'" + ([string]$Value).Replace("'", "''") + "'"
}

function Format-UiBoxValue {
    param(
        [AllowNull()]
        $Value
    )

    if ($null -eq $Value) {
        return "(blank)"
    }

    if ($Value -is [array]) {
        $items = @($Value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($items.Count -eq 0) {
            return "None"
        }

        return ($items -join ", ")
    }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) {
        return "(blank)"
    }

    return $text
}

function New-UiBoxLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [AllowNull()]
        $Value
    )

    return ("{0,-25} {1}" -f ($Label + ":"), (Format-UiBoxValue -Value $Value))
}

function Split-UiTextToWidth {
    param(
        [AllowEmptyString()]
        [string]$Text,

        [Parameter(Mandatory = $true)]
        [int]$Width
    )

    if ($Width -lt 1) {
        return @($Text)
    }

    $lines = @()
    $normalizedText = ([string]$Text) -replace "`r`n", "`n"
    $normalizedText = $normalizedText -replace "`r", "`n"
    foreach ($paragraph in ($normalizedText -split "`n")) {
        $remaining = [string]$paragraph
        if ($remaining.Length -eq 0) {
            $lines += ""
            continue
        }

        while ($remaining.Length -gt $Width) {
            $segment = $remaining.Substring(0, $Width)
            $breakIndex = $segment.LastIndexOf(" ")
            if ($breakIndex -le 0) {
                $breakIndex = $Width
            }

            $lines += $remaining.Substring(0, $breakIndex).TrimEnd()
            $remaining = $remaining.Substring($breakIndex).TrimStart()
        }

        $lines += $remaining
    }

    return $lines
}

function New-UiBoxWrappedLine {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Label,

        [AllowNull()]
        $Value
    )

    $width = if ($script:UiWidth) { $script:UiWidth } else { 120 }
    $innerWidth = [Math]::Max(20, $width - 6)
    $labelText = "{0,-25} " -f ($Label + ":")
    $continuationText = " " * $labelText.Length
    $valueWidth = [Math]::Max(10, $innerWidth - $labelText.Length)
    $wrappedValues = @(Split-UiTextToWidth -Text (Format-UiBoxValue -Value $Value) -Width $valueWidth)

    if ($wrappedValues.Count -eq 0) {
        return @($labelText)
    }

    $lines = @($labelText + $wrappedValues[0])
    for ($i = 1; $i -lt $wrappedValues.Count; $i++) {
        $lines += ($continuationText + $wrappedValues[$i])
    }

    return $lines
}

function ConvertTo-UiTableLines {
    param(
        [AllowNull()]
        [object[]]$Rows,

        [Parameter(Mandatory = $true)]
        [string[]]$Columns
    )

    $cleanRows = @($Rows | Where-Object { $_ })
    if ($cleanRows.Count -eq 0) {
        return @("None")
    }

    $widths = @{}
    foreach ($column in $Columns) {
        $widths[$column] = $column.Length
    }

    foreach ($row in $cleanRows) {
        foreach ($column in $Columns) {
            $valueText = Format-UiBoxValue -Value $row.$column
            if ($valueText.Length -gt $widths[$column]) {
                $widths[$column] = $valueText.Length
            }
        }
    }

    $headerParts = @()
    $dividerParts = @()
    foreach ($column in $Columns) {
        $width = $widths[$column]
        $headerParts += $column.PadRight($width)
        $dividerParts += ("-" * $width)
    }

    $lines = @(
        ($headerParts -join "  ")
        ($dividerParts -join "  ")
    )

    foreach ($row in $cleanRows) {
        $rowParts = @()
        foreach ($column in $Columns) {
            $rowParts += (Format-UiBoxValue -Value $row.$column).PadRight($widths[$column])
        }

        $lines += ($rowParts -join "  ")
    }

    return $lines
}

function Write-UiBox {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title,

        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string[]]$Lines,

        [ConsoleColor]$Color = "Green"
    )

    $width = if ($script:UiWidth) { $script:UiWidth } else { 120 }
    $innerWidth = [Math]::Max(20, $width - 6)
    $horizontal = "-" * ($innerWidth + 2)

    Write-Host ""
    Write-Host ("  +" + $horizontal + "+") -ForegroundColor $Color

    $titleText = " $Title "
    if ($titleText.Length -gt $innerWidth) {
        $titleText = $titleText.Substring(0, $innerWidth - 3) + "..."
    }
    Write-Host ("  | " + $titleText.PadRight($innerWidth) + " |") -ForegroundColor $Color

    Write-Host ("  +" + $horizontal + "+") -ForegroundColor $Color

    foreach ($line in $Lines) {
        $text = [string]$line
        if ($text.Length -gt $innerWidth) {
            $text = $text.Substring(0, $innerWidth - 3) + "..."
        }

        $lineColor = "White"
        $lineLabel = ($text -split ":", 2)[0].Trim()
        if ($lineLabel -match "Enabled") {
            $lineColor = "Yellow"
        }

        Write-Host -NoNewline "  | " -ForegroundColor $Color
        Write-Host -NoNewline $text.PadRight($innerWidth) -ForegroundColor $lineColor
        Write-Host " |" -ForegroundColor $Color
    }

    Write-Host ("  +" + $horizontal + "+") -ForegroundColor $Color
    Write-Host ""
}


function Wait-UiBeat {
    param(
        [int]$Milliseconds = 300
    )

    Start-Sleep -Milliseconds $Milliseconds
}
