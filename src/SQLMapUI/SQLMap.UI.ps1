# SQLMap WinForms UI. Dot-source this file, then call New-SQLMapMainForm.
# The scan runs in a background runspace (Invoke-SQLMapScan -State); a UI timer drains its queues.
# Event handlers keep all state in $script:ui because handler scriptblocks run after the
# function that created them has returned.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, System.Data

$script:UiFont     = New-Object System.Drawing.Font('Segoe UI', 9)
$script:UiFontBold = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
$script:UiFontMono = New-Object System.Drawing.Font('Consolas', 9)
$script:UiSettingsPath = Join-Path $env:APPDATA 'SQLMap\ui-settings.json'

# Same palette as the HTML report. Status colors are text colors and always come with a text label.
function ConvertFrom-UiHex([string]$Hex) { [System.Drawing.ColorTranslator]::FromHtml($Hex) }
$script:UiPalettes = @{
    Dark = @{
        Surface0 = ConvertFrom-UiHex '#121211'; Surface1 = ConvertFrom-UiHex '#1a1a19'; Surface2 = ConvertFrom-UiHex '#242422'
        Input = ConvertFrom-UiHex '#242422'; Border = ConvertFrom-UiHex '#3a3a36'; Hover = ConvertFrom-UiHex '#2e2e2b'
        Text = ConvertFrom-UiHex '#f0efec'; TextSecondary = ConvertFrom-UiHex '#c3c2b7'; Muted = ConvertFrom-UiHex '#9a998f'
        Accent = ConvertFrom-UiHex '#3987e5'; AccentHover = ConvertFrom-UiHex '#5598e7'; OnAccent = ConvertFrom-UiHex '#ffffff'
        Selection = ConvertFrom-UiHex '#1c5cab'; AltRow = ConvertFrom-UiHex '#1f1f1e'
        Critical = ConvertFrom-UiHex '#f07a7a'; Warning = ConvertFrom-UiHex '#fab219'; Good = ConvertFrom-UiHex '#4cc44c'
        WinTheme = 'DarkMode_Explorer'; DarkTitle = 1
    }
    Light = @{
        Surface0 = ConvertFrom-UiHex '#f4f3f0'; Surface1 = ConvertFrom-UiHex '#fcfcfb'; Surface2 = ConvertFrom-UiHex '#ecebe7'
        Input = ConvertFrom-UiHex '#ffffff'; Border = ConvertFrom-UiHex '#d6d5cf'; Hover = ConvertFrom-UiHex '#e4e3de'
        Text = ConvertFrom-UiHex '#0b0b0b'; TextSecondary = ConvertFrom-UiHex '#52514e'; Muted = ConvertFrom-UiHex '#6e6e69'
        Accent = ConvertFrom-UiHex '#2a78d6'; AccentHover = ConvertFrom-UiHex '#256abf'; OnAccent = ConvertFrom-UiHex '#ffffff'
        Selection = ConvertFrom-UiHex '#2a78d6'; AltRow = ConvertFrom-UiHex '#f6f6f3'
        Critical = ConvertFrom-UiHex '#b02727'; Warning = ConvertFrom-UiHex '#8a5a00'; Good = ConvertFrom-UiHex '#006300'
        WinTheme = 'Explorer'; DarkTitle = 0
    }
}
$script:UiTheme   = 'Dark'
$script:UiPalette = $script:UiPalettes.Dark
$script:UiColors  = @{ Critical = $script:UiPalette.Critical; Warning = $script:UiPalette.Warning; Good = $script:UiPalette.Good; Muted = $script:UiPalette.Muted }

# Dark title bar (Windows 10 20H1+ / 11) and dark native scrollbars
if (-not ('SQLMapUi.Native' -as [type])) {
    Add-Type -Namespace SQLMapUi -Name Native -MemberDefinition @'
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hwnd, string appName, string idList);
'@
}

#region Control helpers ------------------------------------------------------------------

function New-UiLabel {
    param([string]$Text, [switch]$Bold, [switch]$Muted)
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $Text
    $l.AutoSize = $true
    $l.Margin = New-Object System.Windows.Forms.Padding(3, 7, 3, 2)
    if ($Bold) { $l.Font = $script:UiFontBold }
    if ($Muted) { $l.Tag = 'muted'; $l.ForeColor = $script:UiPalette.Muted }
    $l
}

function New-UiTextBox {
    param([string]$Text = '', [switch]$Multiline, [int]$Lines = 4)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Text = $Text
    $t.Dock = 'Fill'
    if ($Multiline) {
        $t.Multiline = $true
        $t.AcceptsReturn = $true
        $t.ScrollBars = 'Vertical'
        $t.WordWrap = $false
        $t.Height = 8 + $Lines * 16
    }
    $t
}

function New-UiCheckBox {
    param([string]$Text, [bool]$Checked = $false, [switch]$Bold)
    $c = New-Object System.Windows.Forms.CheckBox
    $c.Text = $Text
    $c.Checked = $Checked
    $c.AutoSize = $true
    $c.Margin = New-Object System.Windows.Forms.Padding(3, 8, 3, 2)
    if ($Bold) { $c.Font = $script:UiFontBold }
    $c
}

function New-UiRadio {
    param([string]$Text, [bool]$Checked = $false)
    $r = New-Object System.Windows.Forms.RadioButton
    $r.Text = $Text
    $r.Checked = $Checked
    $r.AutoSize = $true
    $r
}

function New-UiButton {
    param([string]$Text, [int]$MinWidth = 80, [switch]$Primary)
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $Text
    $b.AutoSize = $true
    $b.AutoSizeMode = 'GrowAndShrink'
    $b.FlatStyle = 'Flat'
    $b.Padding = New-Object System.Windows.Forms.Padding(8, 3, 8, 3)
    $b.MinimumSize = New-Object System.Drawing.Size($MinWidth, 0)
    if ($Primary) {
        $b.Tag = 'primary'; $b.Font = $script:UiFontBold
        $b.Add_EnabledChanged({ param($s, $e) Set-UiControlColors $s })
    }
    $b
}

function New-UiNumeric {
    param([int]$Min, [int]$Max, [int]$Value, [int]$Increment = 1)
    $n = New-Object System.Windows.Forms.NumericUpDown
    $n.Minimum = $Min; $n.Maximum = $Max; $n.Value = $Value; $n.Increment = $Increment
    $n.Width = 90
    $n.Anchor = 'Left'
    $n
}

function New-UiStack {
    # One-column, auto-growing layout
    $p = New-Object System.Windows.Forms.TableLayoutPanel
    $p.ColumnCount = 1
    $p.Dock = 'Top'
    $p.AutoSize = $true
    $p.AutoSizeMode = 'GrowAndShrink'
    $p.GrowStyle = 'AddRows'
    $p.Padding = New-Object System.Windows.Forms.Padding(6)
    [void]$p.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $p
}

function New-UiGrid2 {
    # Two-column label/control layout
    $p = New-Object System.Windows.Forms.TableLayoutPanel
    $p.ColumnCount = 2
    $p.Dock = 'Fill'
    $p.AutoSize = $true
    $p.AutoSizeMode = 'GrowAndShrink'
    $p.GrowStyle = 'AddRows'
    $p.Margin = New-Object System.Windows.Forms.Padding(18, 0, 3, 3)
    [void]$p.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$p.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $p
}

function Add-UiRow {
    param($Grid, [string]$Label, $Control)
    $Grid.Controls.Add((New-UiLabel $Label))
    $Grid.Controls.Add($Control)
}

function New-UiTabSet {
    # Themeable replacement for TabControl (whose headers cannot be dark): a row of flat
    # toggle buttons over a content panel. Returns @{ Root; Buttons; Pages }.
    param([string[]]$Titles)
    $root = New-Object System.Windows.Forms.TableLayoutPanel
    $root.ColumnCount = 1; $root.RowCount = 2
    $root.Dock = 'Fill'
    $root.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    [void]$root.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $header = New-Object System.Windows.Forms.FlowLayoutPanel
    $header.AutoSize = $true; $header.Dock = 'Fill'; $header.WrapContents = $false
    $header.Margin = New-Object System.Windows.Forms.Padding(0)
    $content = New-Object System.Windows.Forms.Panel
    $content.Dock = 'Fill'
    $content.Margin = New-Object System.Windows.Forms.Padding(0)
    $content.Tag = 'page'
    $root.Controls.Add($header, 0, 0)
    $root.Controls.Add($content, 0, 1)

    $set = @{ Root = $root; Buttons = New-Object System.Collections.Generic.List[object]; Pages = New-Object System.Collections.Generic.List[object] }
    foreach ($title in $Titles) {
        $page = New-Object System.Windows.Forms.Panel
        $page.Dock = 'Fill'; $page.AutoScroll = $true; $page.Visible = $false; $page.Tag = 'page'
        $page.Padding = New-Object System.Windows.Forms.Padding(2)
        $btn = New-Object System.Windows.Forms.RadioButton
        $btn.Appearance = 'Button'
        $btn.FlatStyle = 'Flat'
        $btn.FlatAppearance.BorderSize = 0
        $btn.AutoSize = $true
        $btn.Text = $title
        $btn.TextAlign = 'MiddleCenter'
        $btn.Margin = New-Object System.Windows.Forms.Padding(0, 0, 2, 0)
        $btn.Padding = New-Object System.Windows.Forms.Padding(10, 4, 10, 4)
        $btn.Tag = @{ Role = 'tab'; Page = $page }
        $btn.Add_CheckedChanged({ param($s, $e) if ($s.Checked) { Select-UiTabButton $s } })
        $header.Controls.Add($btn)
        $content.Controls.Add($page)
        $set.Buttons.Add($btn)
        $set.Pages.Add($page)
    }
    $set.Buttons[0].Checked = $true
    Select-UiTabButton $set.Buttons[0]
    $set
}

function Select-UiTabButton {
    param($Button)
    foreach ($b in $Button.Parent.Controls) {
        $b.Tag.Page.Visible = $b.Checked
        Set-UiTabStyle $b
    }
    if ($Button.Tag.Page.IsHandleCreated) { Set-UiNativeTheme $Button.Tag.Page }
}

function Select-UiTab {
    param($Set, [int]$Index)
    $Set.Buttons[$Index].Checked = $true
}

function Set-UiTabStyle {
    param($Button)
    $p = $script:UiPalette
    $Button.FlatAppearance.CheckedBackColor = $p.Surface1
    $Button.FlatAppearance.MouseOverBackColor = $(if ($Button.Checked) { $p.Surface1 } else { $p.Hover })
    $Button.BackColor = $(if ($Button.Checked) { $p.Surface1 } else { $p.Surface0 })
    $Button.ForeColor = $(if ($Button.Checked) { $p.Text } else { $p.Muted })
    $Button.Font = $(if ($Button.Checked) { $script:UiFontBold } else { $script:UiFont })
}

function New-UiDataGrid {
    $g = New-Object System.Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.ReadOnly = $true
    $g.AllowUserToAddRows = $false
    $g.AllowUserToDeleteRows = $false
    $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.MultiSelect = $true
    $g.BackgroundColor = [System.Drawing.SystemColors]::Window
    $g.BorderStyle = 'None'
    $g.AutoSizeColumnsMode = 'None'
    $g.ColumnHeadersHeightSizeMode = 'AutoSize'
    $g.DefaultCellStyle.Font = $script:UiFont
    $g.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(248, 248, 246)
    # Reduce flicker while rows stream in
    $g.GetType().GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'NonPublic,Instance').SetValue($g, $true, $null)
    $g
}

#endregion

#region Theme --------------------------------------------------------------------------------

function Get-UiRole {
    param($Control)
    $t = $Control.Tag
    if ($t -is [hashtable]) { return [string]$t.Role }
    [string]$t
}

function Set-UiControlColors {
    # Colors one control by type/role, then its children. Unset BackColors inherit from the parent.
    param($Control)
    $p = $script:UiPalette
    $role = Get-UiRole $Control
    switch ($Control.GetType().Name) {
        'Form' { $Control.BackColor = $p.Surface0; $Control.ForeColor = $p.Text }
        'SplitContainer' { $Control.BackColor = $p.Border }
        'SplitterPanel' { $Control.BackColor = $p.Surface0 }
        { $_ -in 'Panel', 'TableLayoutPanel', 'FlowLayoutPanel' } {
            if ($role -eq 'page') { $Control.BackColor = $p.Surface1 }
            elseif ($role -eq 'bar') { $Control.BackColor = $p.Surface0 }
            elseif ($role -eq 'track') { $Control.BackColor = $p.Surface2 }
            elseif ($role -eq 'fill') { $Control.BackColor = $p.Accent }
        }
        { $_ -in 'TextBox', 'NumericUpDown' } {
            $Control.BackColor = $p.Input; $Control.ForeColor = $p.Text; $Control.BorderStyle = 'FixedSingle'
        }
        'Button' {
            $Control.FlatStyle = 'Flat'
            $Control.UseVisualStyleBackColor = $false
            if ($role -eq 'primary' -and -not $Control.Enabled) {
                # Flat buttons keep their colors when disabled: show a disabled primary as neutral
                $Control.BackColor = $p.Surface2; $Control.ForeColor = $p.Muted
                $Control.FlatAppearance.BorderColor = $p.Border
            }
            elseif ($role -eq 'primary') {
                $Control.BackColor = $p.Accent; $Control.ForeColor = $p.OnAccent
                $Control.FlatAppearance.BorderColor = $p.Accent
                $Control.FlatAppearance.MouseOverBackColor = $p.AccentHover
                $Control.FlatAppearance.MouseDownBackColor = $p.Selection
            }
            else {
                $Control.BackColor = $p.Surface2; $Control.ForeColor = $p.Text
                $Control.FlatAppearance.BorderColor = $p.Border
                $Control.FlatAppearance.MouseOverBackColor = $p.Hover
                $Control.FlatAppearance.MouseDownBackColor = $p.Border
            }
        }
        'RadioButton' { if ($role -eq 'tab') { Set-UiTabStyle $Control } else { $Control.ForeColor = $p.Text } }
        'CheckBox' { $Control.ForeColor = $p.Text }
        'Label' { $Control.ForeColor = $(if ($role -eq 'muted') { $p.Muted } else { $p.Text }) }
        'DataGridView' {
            $Control.EnableHeadersVisualStyles = $false
            $Control.BackgroundColor = $p.Surface1
            $Control.GridColor = $p.Border
            $Control.CellBorderStyle = 'SingleHorizontal'
            $Control.ColumnHeadersBorderStyle = 'Single'
            $Control.DefaultCellStyle.BackColor = $p.Surface1
            $Control.DefaultCellStyle.ForeColor = $p.Text
            $Control.DefaultCellStyle.SelectionBackColor = $p.Selection
            $Control.DefaultCellStyle.SelectionForeColor = $p.OnAccent
            $Control.AlternatingRowsDefaultCellStyle.BackColor = $p.AltRow
            $Control.ColumnHeadersDefaultCellStyle.BackColor = $p.Surface2
            $Control.ColumnHeadersDefaultCellStyle.ForeColor = $p.TextSecondary
            $Control.ColumnHeadersDefaultCellStyle.SelectionBackColor = $p.Surface2
            $Control.ColumnHeadersDefaultCellStyle.SelectionForeColor = $p.TextSecondary
            $Control.ColumnHeadersDefaultCellStyle.Font = $script:UiFontBold
        }
    }
    foreach ($child in $Control.Controls) { Set-UiControlColors $child }
}

function Set-UiNativeTheme {
    # Dark/light native scrollbars (text boxes, scrolling panels, grid scrollbars). Needs created handles.
    # Only window classes whose painting is native: controls that paint themselves with
    # VisualStyleRenderer (NumericUpDown spin buttons, DataGridView) throw "Visual Style handle
    # creation operation did not succeed" when their window theme is changed.
    param($Control)
    $isTarget = ($Control -is [System.Windows.Forms.ScrollBar]) -or ($Control.GetType().Name -in 'TextBox', 'Panel')
    if ($Control.IsHandleCreated -and $isTarget) {
        [void][SQLMapUi.Native]::SetWindowTheme($Control.Handle, $script:UiPalette.WinTheme, $null)
    }
    foreach ($child in $Control.Controls) { Set-UiNativeTheme $child }
}

function Set-UiTitleBar {
    param($Form)
    if (-not $Form.IsHandleCreated) { return }
    $v = [int]$script:UiPalette.DarkTitle
    # 20 = DWMWA_USE_IMMERSIVE_DARK_MODE (Windows 10 20H1+), 19 on older Windows 10 builds
    if ([SQLMapUi.Native]::DwmSetWindowAttribute($Form.Handle, 20, [ref]$v, 4) -ne 0) {
        [void][SQLMapUi.Native]::DwmSetWindowAttribute($Form.Handle, 19, [ref]$v, 4)
    }
}

function Set-UiTheme {
    # Applies 'Dark' or 'Light' to a form (main window or dialog)
    param($Form, [ValidateSet('Dark', 'Light')][string]$Theme = $script:UiTheme)
    $script:UiTheme = $Theme
    $script:UiPalette = $script:UiPalettes[$Theme]
    $p = $script:UiPalette
    $script:UiColors = @{ Critical = $p.Critical; Warning = $p.Warning; Good = $p.Good; Muted = $p.Muted }
    $Form.SuspendLayout()
    try { Set-UiControlColors $Form }
    finally { $Form.ResumeLayout() }
    Set-UiNativeTheme $Form
    Set-UiTitleBar $Form
    $Form.Refresh()
}

function Switch-UiTheme {
    $u = $script:ui
    $new = if ($script:UiTheme -eq 'Dark') { 'Light' } else { 'Dark' }
    Set-UiTheme $u.Form $new
    $u.BtnTheme.Text = $(if ($new -eq 'Dark') { 'Light theme' } else { 'Dark theme' })
    Save-UiSettings
}

function New-UiProgress {
    # Themeable progress bar (the native one cannot be dark): an accent fill on a track panel
    $track = New-Object System.Windows.Forms.Panel
    $track.Height = 8
    $track.Anchor = 'Left,Right'
    $track.Margin = New-Object System.Windows.Forms.Padding(3, 6, 3, 4)
    $track.Tag = 'track'
    $fill = New-Object System.Windows.Forms.Panel
    $fill.Tag = 'fill'
    $fill.SetBounds(0, 0, 0, 8)
    $track.Controls.Add($fill)
    $track.Add_Resize({ Update-UiProgress })
    @{ Track = $track; Fill = $fill; Value = 0; Maximum = 1; Indeterminate = $false; Pos = 0.0 }
}

function Set-UiProgress {
    param([int]$Value = 0, [int]$Maximum = 1, [switch]$Indeterminate)
    $u = $script:ui
    $p = $u.Progress
    $p.Indeterminate = [bool]$Indeterminate
    $p.Maximum = [Math]::Max(1, $Maximum)
    $p.Value = [Math]::Max(0, [Math]::Min($Value, $p.Maximum))
    if ($Indeterminate) { $u.MarqueeTimer.Start() } else { $u.MarqueeTimer.Stop() }
    Update-UiProgress
}

function Update-UiProgress {
    $u = $script:ui
    if (-not $u -or -not $u.Progress) { return }
    $p = $u.Progress
    $w = $p.Track.ClientSize.Width; $h = $p.Track.ClientSize.Height
    if ($p.Indeterminate) {
        # A block a quarter of the width sliding left to right
        $bw = [int]($w * 0.25)
        $x = [int]((($p.Pos % 125) / 100.0) * $w) - $bw
        $p.Fill.SetBounds($x, 0, $bw, $h)
    }
    else {
        $p.Fill.SetBounds(0, 0, [int]($w * $p.Value / $p.Maximum), $h)
    }
}

function Format-UiDuration {
    # 45 s | 8 min 10 s | 1 h 05 min
    param([TimeSpan]$Span)
    $s = [int][Math]::Ceiling($Span.TotalSeconds)
    if ($s -lt 60) { return "$s s" }
    if ($s -lt 3600) { return ('{0} min {1:00} s' -f [int][Math]::Floor($s / 60), ($s % 60)) }
    '{0} h {1:00} min' -f [int][Math]::Floor($s / 3600), [int][Math]::Floor(($s % 3600) / 60)
}

function Get-UiProgressText {
    # '37%  -  about 8 min 10 s left'. The estimate is the average pace since scanning started (hosts run in
    # parallel, so the overall rate is steadier than per-host times); it waits for 1% of the hosts or 5 seconds.
    param([int]$Done, [int]$Total, [double]$ScanSeconds)
    if ($Total -le 0) { return '' }
    $pct = [int][Math]::Floor(100.0 * $Done / $Total)
    if ($Done -ge $Total) { return '100%' }
    if ($Done -lt [Math]::Max(3, [int]($Total * 0.01)) -or $ScanSeconds -lt 5) { return "$pct%  -  estimating time left..." }
    $left = [TimeSpan]::FromSeconds($ScanSeconds / $Done * ($Total - $Done))
    "$pct%  -  about $(Format-UiDuration $left) left"
}

function Show-UiError {
    param([string]$Message, [string]$Title = 'SQLMap')
    [void][System.Windows.Forms.MessageBox]::Show($script:ui.Form, $Message, $Title, 'OK', 'Error')
}

function Invoke-UiSafe {
    # Event handler wrapper: an exception becomes a message box instead of a silent console error
    param([scriptblock]$Action)
    try { & $Action }
    catch { Show-UiError ("Unexpected error: " + $_.Exception.Message) }
}

#endregion

#region Dialogs ----------------------------------------------------------------------------

function Initialize-UiDialog {
    # Same icon and theme as the main window
    param($Form)
    if ($script:ui -and $script:ui.Icon) { $Form.Icon = $script:ui.Icon } else { $Form.ShowIcon = $false }
    Set-UiControlColors $Form
    $Form.Add_Shown({ param($s, $e) Set-UiNativeTheme $s; Set-UiTitleBar $s })
}

function Read-UiCredential {
    # Small credential dialog (works on Windows PowerShell and PowerShell 7). The password is
    # converted to a SecureString immediately and is never stored on disk.
    param([string]$Title, [string]$UserName = '', [string]$Hint)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.Font = $script:UiFont
    $f.FormBorderStyle = 'FixedDialog'
    $f.StartPosition = 'CenterParent'
    $f.MinimizeBox = $false; $f.MaximizeBox = $false
    $f.AutoSize = $true
    $f.AutoSizeMode = 'GrowAndShrink'
    $f.Padding = New-Object System.Windows.Forms.Padding(10)

    $stack = New-UiStack
    $stack.Dock = 'None'   # docked, the stack and the auto-sized form would size each other down to nothing
    $stack.Location = New-Object System.Drawing.Point(10, 10)
    if ($Hint) { $h = New-UiLabel $Hint -Muted; $h.MaximumSize = New-Object System.Drawing.Size(380, 0); $stack.Controls.Add($h) }
    $grid = New-UiGrid2
    $grid.Margin = New-Object System.Windows.Forms.Padding(0)
    $user = New-UiTextBox $UserName
    $user.Width = 260
    $pass = New-UiTextBox
    $pass.UseSystemPasswordChar = $true
    Add-UiRow $grid 'User name' $user
    Add-UiRow $grid 'Password' $pass
    $stack.Controls.Add($grid)

    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'
    $buttons.AutoSize = $true
    $buttons.Dock = 'Fill'
    $ok = New-UiButton 'OK'
    $cancel = New-UiButton 'Cancel'
    $ok.DialogResult = 'OK'; $cancel.DialogResult = 'Cancel'
    $buttons.Controls.AddRange(@($cancel, $ok))
    $stack.Controls.Add($buttons)
    $f.Controls.Add($stack)
    $f.AcceptButton = $ok; $f.CancelButton = $cancel
    $ok.Tag = 'primary'; $ok.Font = $script:UiFontBold
    Initialize-UiDialog $f
    if ($UserName) { $f.Add_Shown({ $pass.Focus() }.GetNewClosure()) }

    $cred = $null
    if ($f.ShowDialog($script:ui.Form) -eq 'OK' -and $user.Text.Trim()) {
        $secure = New-Object System.Security.SecureString
        foreach ($ch in $pass.Text.ToCharArray()) { $secure.AppendChar($ch) }
        $secure.MakeReadOnly()
        $cred = New-Object System.Management.Automation.PSCredential($user.Text.Trim(), $secure)
    }
    $pass.Text = ''
    $f.Dispose()
    $cred
}

function Show-UiDetail {
    param([string]$Title, [string]$Text)
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $Title
    $f.Font = $script:UiFont
    $f.StartPosition = 'CenterParent'
    $f.Size = New-Object System.Drawing.Size(900, 640)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Multiline = $true; $t.ReadOnly = $true; $t.ScrollBars = 'Both'; $t.WordWrap = $false
    $t.Dock = 'Fill'; $t.Font = $script:UiFontMono
    $t.Text = $Text
    $f.Controls.Add($t)
    Initialize-UiDialog $f
    $t.BorderStyle = 'None'
    $f.Add_Shown({ $t.SelectionLength = 0 }.GetNewClosure())
    [void]$f.ShowDialog($script:ui.Form)
    $f.Dispose()
}

function Format-UiDetail {
    # Plain-text view of an instance or a host (with probes, services and log)
    param($Object, [ValidateSet('Instance', 'Host')][string]$Kind)
    $sb = New-Object System.Text.StringBuilder
    $skip = @('Probes', 'ProbeMessages', 'Services', 'Log', 'HostInfo', 'Instances')
    $props = $Object.PSObject.Properties | Where-Object { $_.Name -notin $skip }
    $width = ($props | ForEach-Object { $_.Name.Length } | Measure-Object -Maximum).Maximum
    foreach ($p in $props) {
        $v = $p.Value
        if ($v -is [System.Collections.IEnumerable] -and $v -isnot [string]) { $v = (@($v) | ForEach-Object { "$_" }) -join ', ' }
        [void]$sb.AppendLine(('{0} : {1}' -f $p.Name.PadRight($width), $v))
    }
    if ($Kind -eq 'Host') {
        if ($Object.HostInfo) {
            [void]$sb.AppendLine(); [void]$sb.AppendLine('== Host info')
            [void]$sb.AppendLine(($Object.HostInfo | Format-List | Out-String -Width 200).Trim())
        }
        [void]$sb.AppendLine(); [void]$sb.AppendLine('== Probes')
        $pm = $Object.ProbeMessages
        $probeRows = foreach ($k in (Get-UiKeys $Object.Probes)) {
            [pscustomobject]@{ Probe = $k; Result = (Get-UiValue $Object.Probes $k); Message = (Get-UiValue $pm $k) }
        }
        [void]$sb.AppendLine(($probeRows | Format-Table -AutoSize | Out-String -Width 400).Trim())
        if ($Object.Services) {
            [void]$sb.AppendLine(); [void]$sb.AppendLine('== SQL Server services')
            [void]$sb.AppendLine((@($Object.Services) | Format-Table Name, ServiceType, InstanceName, State, StartMode, StartName -AutoSize | Out-String -Width 400).Trim())
        }
        [void]$sb.AppendLine(); [void]$sb.AppendLine('== Scan log')
        foreach ($l in @($Object.Log)) { if ($l) { [void]$sb.AppendLine("$($l.Time)  $($l.Level.PadRight(7))  $($l.Message)") } }
    }
    $sb.ToString()
}

function Get-UiKeys {
    # Keys of an ordered dictionary (live results) or property names of a PSCustomObject (loaded JSON)
    param($Object)
    if ($null -eq $Object) { return @() }
    if ($Object -is [System.Collections.IDictionary]) { return @($Object.Keys) }
    @($Object.PSObject.Properties | ForEach-Object { $_.Name })
}

function Get-UiValue {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

#endregion

#region Result grids -----------------------------------------------------------------------

function New-UiTables {
    $inst = New-Object System.Data.DataTable 'Instances'
    foreach ($c in 'Instance', 'Type', 'Product', 'Build', 'Level', 'Latest update', 'Edition', 'State', 'Port', 'Support', 'Components', 'Confidence', 'Host') {
        [void]$inst.Columns.Add($c, [string])
    }
    [void]$inst.Columns.Add('Idx', [int])

    $hosts = New-Object System.Data.DataTable 'Hosts'
    foreach ($c in 'Host', 'IP', 'Status') { [void]$hosts.Columns.Add($c, [string]) }
    [void]$hosts.Columns.Add('Instances', [int])
    foreach ($c in 'Types', 'OS') { [void]$hosts.Columns.Add($c, [string]) }
    [void]$hosts.Columns.Add('Cores', [int])
    [void]$hosts.Columns.Add('Memory GB', [double])
    foreach ($c in 'Ping', 'Registry', 'Services', 'Browser', 'SQL connect', 'Detail') { [void]$hosts.Columns.Add($c, [string]) }
    [void]$hosts.Columns.Add('Scan ms', [int])
    [void]$hosts.Columns.Add('Idx', [int])
    @{ Instances = $inst; Hosts = $hosts }
}

function ConvertTo-UiDbValue {
    param($Value)
    if ($null -eq $Value -or "$Value" -eq '') { return [DBNull]::Value }
    $Value
}

function Add-UiHostResult {
    # Adds one host (and, unless -SkipInstances, its instances) to the grids
    param($HostResult, [switch]$SkipInstances)
    $u = $script:ui
    $u.HostObjects.Add($HostResult)
    $hi = $HostResult.HostInfo
    $pr = $HostResult.Probes
    $row = $u.Tables.Hosts.NewRow()
    $row['Host']        = $HostResult.ComputerName
    $row['IP']          = ConvertTo-UiDbValue $HostResult.IPAddress
    $row['Status']      = $HostResult.Status
    $row['Instances']   = [int]$HostResult.InstanceCount
    $row['Types']       = ConvertTo-UiDbValue (Get-UiValue $HostResult 'InstanceTypes')   # 'Engine 1, SSRS 1'
    $row['OS']          = ConvertTo-UiDbValue $(if ($hi) { $hi.OSCaption } else { $HostResult.AdOperatingSystem })
    $row['Cores']       = ConvertTo-UiDbValue $(if ($hi) { $hi.Cores } else { $null })
    $row['Memory GB']   = ConvertTo-UiDbValue $(if ($hi) { $hi.MemoryGB } else { $null })
    $row['Ping']        = ConvertTo-UiDbValue (Get-UiValue $pr 'Ping')
    $row['Registry']    = ConvertTo-UiDbValue (Get-UiValue $pr 'Registry')
    $row['Services']    = ConvertTo-UiDbValue (Get-UiValue $pr 'Service')
    $row['Browser']     = ConvertTo-UiDbValue (Get-UiValue $pr 'Browser')
    $row['SQL connect'] = ConvertTo-UiDbValue (Get-UiValue $pr 'SqlConnect')
    $row['Detail']      = ConvertTo-UiDbValue $HostResult.StatusDetail
    $row['Scan ms']     = ConvertTo-UiDbValue $HostResult.DurationMs
    $row['Idx']         = $u.HostObjects.Count - 1
    $u.Tables.Hosts.Rows.Add($row)
    if (-not $SkipInstances -and $HostResult.PSObject.Properties['Instances']) {
        foreach ($i in @($HostResult.Instances)) { if ($i) { Add-UiInstance $i } }
    }
}

function Add-UiInstance {
    param($Instance)
    $u = $script:ui
    $u.InstanceObjects.Add($Instance)
    $i = $Instance
    $row = $u.Tables.Instances.NewRow()
    $row['Instance']   = $i.SqlInstance
    $row['Type']       = $i.ServiceType
    $row['Product']    = ConvertTo-UiDbValue $i.ProductName
    $row['Build']      = ConvertTo-UiDbValue $i.Version
    $level = if ($i.UpdateLevel -and ($i.UpdateLevel -match '^(SP|RTM|Newer)' -or -not $i.ProductLevel -or $i.ProductLevel -eq 'RTM')) { $i.UpdateLevel }
             else { (@($i.ProductLevel, $i.UpdateLevel) | Where-Object { $_ }) -join ' ' }
    $row['Level']      = ConvertTo-UiDbValue $level
    $row['Latest update'] = ConvertTo-UiDbValue $(switch ($i.PatchStatus) {
        'Latest' { "Latest ($($i.LatestUpdate))" }
        'Behind' { "$($i.UpdatesBehind) behind (latest $($i.LatestUpdate))" }
        'Security update missing' { "Security update missing, $($i.UpdatesBehind) behind (latest $($i.LatestUpdate))" }
        'Newer than reference' { 'Newer than reference' }
        'Not covered' { 'Not in reference' }
        default { $null }
    })
    $row['Edition']    = ConvertTo-UiDbValue $i.Edition
    $row['State']      = $(if ($i.IsRunning -eq $true) { 'Running' } elseif ($i.IsRunning -eq $false) { 'Stopped' } else { 'Unknown' })
    $row['Port']       = ConvertTo-UiDbValue $(if ($i.TcpPort) { "$($i.TcpPort)" + $(if ($i.DynamicPort) { ' (dyn)' } else { '' }) } else { $null })
    $row['Support']    = ConvertTo-UiDbValue $i.SupportStatus
    $row['Components'] = ConvertTo-UiDbValue ((@($i.Components) | Where-Object { $_ }) -join ', ')
    $row['Confidence'] = ConvertTo-UiDbValue $i.Confidence
    $row['Host']       = $i.ComputerName
    $row['Idx']        = $u.InstanceObjects.Count - 1
    $u.Tables.Instances.Rows.Add($row)
}

function Clear-UiResults {
    $u = $script:ui
    $u.Tables.Instances.Clear()
    $u.Tables.Hosts.Clear()
    $u.HostObjects.Clear()
    $u.InstanceObjects.Clear()
}

function Show-UiScan {
    # Replaces the grids with a complete scan (final result or a loaded JSON file)
    param($Scan)
    $u = $script:ui
    $u.GridInstances.SuspendLayout(); $u.GridHosts.SuspendLayout()
    try {
        Clear-UiResults
        # Final scans keep instances at the top level (hosts were merged/de-duplicated at the end)
        foreach ($h in @($Scan.Hosts)) { if ($h) { Add-UiHostResult $h -SkipInstances } }
        foreach ($i in @($Scan.Instances)) { if ($i) { Add-UiInstance $i } }
    }
    finally { $u.GridInstances.ResumeLayout(); $u.GridHosts.ResumeLayout() }
    Update-UiSummary
    Resize-UiGrids
}

function Resize-UiGrids {
    $u = $script:ui
    foreach ($g in $u.GridInstances, $u.GridHosts) {
        if ($g.Columns.Count) {
            $g.AutoResizeColumns([System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::DisplayedCells)
            foreach ($col in $g.Columns) { if ($col.Width -gt 420) { $col.Width = 420 } }
        }
        Set-UiNativeTheme $g   # grid scrollbars appear with the first rows
    }
}

function Update-UiSummary {
    $u = $script:ui
    $hosts = $u.Tables.Hosts.Rows.Count
    $withSql = @($u.Tables.Hosts.Select("Status = 'SQLFound'")).Count
    $notVerified = @($u.Tables.Hosts.Select("Status IN ('Inconclusive','Unreachable','Unresolved','Timeout','Error','Cancelled')")).Count
    $instances = $u.Tables.Instances.Rows.Count
    $oos = @($u.Tables.Instances.Select("Type = 'Engine' AND Support = 'Out of support'")).Count
    $behind = @($u.Tables.Instances.Select("Type = 'Engine' AND [Latest update] LIKE '%behind%'")).Count
    $denied = @($u.Tables.Hosts.Select("Status = 'Inconclusive' AND Detail LIKE 'Access denied%'")).Count
    $deniedText = if ($denied) { " ($denied access denied: use a local administrator account)" } else { '' }
    $u.LblSummary.Text = "Hosts: $hosts    With SQL Server: $withSql    Instances: $instances    Out of support: $oos    Behind latest update: $behind    Not verified: $notVerified$deniedText"
    $u.TabInstances.Text = "Instances ($instances)"
    $u.TabHosts.Text = "Hosts ($hosts)"
}

function Set-UiGridColors {
    param($Grid)
    # Status text colors (always together with the text itself, never color alone)
    $Grid.Add_CellFormatting({
        param($s, $e)
        if ($e.RowIndex -lt 0 -or $e.ColumnIndex -lt 0) { return }
        $name = $s.Columns[$e.ColumnIndex].DataPropertyName
        $v = [string]$e.Value
        $c = $null
        switch ($name) {
            'Support' {
                if ($v -eq 'Out of support') { $c = $script:UiColors.Critical }
                elseif ($v -eq 'Extended support') { $c = $script:UiColors.Warning }
            }
            'Status' {
                if ($v -in 'Error', 'Timeout') { $c = $script:UiColors.Critical }
                elseif ($v -eq 'Inconclusive') { $c = $script:UiColors.Warning }
                elseif ($v -in 'Unreachable', 'Unresolved', 'Cancelled', 'NoSQLFound') { $c = $script:UiColors.Muted }
            }
            { $_ -in 'Ping', 'Registry', 'Services', 'Browser', 'SQL connect' } {
                if ($v -eq 'AccessDenied') { $c = $script:UiColors.Critical }
                elseif ($v -eq 'OK') { $c = $script:UiColors.Good }
                elseif ($v -in 'Skipped', 'NoReply', 'Closed', 'NoTarget') { $c = $script:UiColors.Muted }
                elseif ($v) { $c = $script:UiColors.Warning }
            }
            'State' { if ($v -eq 'Running') { $c = $script:UiColors.Good } elseif ($v -ne 'Stopped') { $c = $script:UiColors.Muted } }
            'Latest update' {
                if ($v -like 'Latest*') { $c = $script:UiColors.Good }
                elseif ($v -like '*behind*') { $c = $script:UiColors.Warning }
                elseif ($v) { $c = $script:UiColors.Muted }
            }
        }
        if ($c) { $e.CellStyle.ForeColor = $c }
    })
}

#endregion

#region Build reference update ---------------------------------------------------------------
# At startup, when the build reference is older than its freshness window (MaxAgeDays, 30) and the online check is
# on, a background test sees whether Microsoft Learn is reachable; only then the user is asked. Nothing is
# downloaded without a click. 'Not now' waits 7 days; 'Don't ask again' turns the check off (Options tab).

function Start-UiBackgroundTask {
    # Runs $Script in its own runspace (module loaded); $OnDone gets (result, errorText) on the UI thread
    param([string]$Name, [scriptblock]$Script, [scriptblock]$OnDone)
    $u = $script:ui
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule([string[]]@($u.ModulePath))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript($Script.ToString())
    $u.BgTasks.Add(@{ Name = $Name; PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); OnDone = $OnDone })
    if (-not $u.BgTimer.Enabled) { $u.BgTimer.Start() }
}

function Invoke-UiBackgroundTick {
    $u = $script:ui
    foreach ($t in @($u.BgTasks.ToArray())) {
        if (-not $t.Handle.IsCompleted) { continue }
        $result = $null; $err = $null
        try {
            $result = $t.PS.EndInvoke($t.Handle) | Select-Object -Last 1
            if ($t.PS.Streams.Error.Count) { $err = [string]$t.PS.Streams.Error[0] }
        }
        catch { $err = $_.Exception.InnerException.Message; if (-not $err) { $err = $_.Exception.Message } }
        finally { $t.PS.Dispose(); $t.Runspace.Dispose(); [void]$u.BgTasks.Remove($t) }
        Invoke-UiSafe { & $t.OnDone $result $err }
    }
    if ($u.BgTasks.Count -eq 0) { $u.BgTimer.Stop() }
}

function Get-UiBuildRefInfo {
    # The reference as this window's module sees it, plus its age in days (null when there is no file)
    $ref = & (Get-Module SQLMap) { Get-SQLMapBuildReference }
    $age = if ($ref.Available -and $ref.RetrievedUtc) { [int][Math]::Floor(((Get-Date).ToUniversalTime() - $ref.RetrievedUtc.ToUniversalTime()).TotalDays) } else { $null }
    @{ Ref = $ref; AgeDays = $age }
}

function Update-UiBuildRefLabel {
    $u = $script:ui
    $info = Get-UiBuildRefInfo
    $u.LblBuildRef.Text = if (-not $info.Ref.Available) { 'No build reference file: patch levels are not shown.' }
        else {
            $old = if ($info.AgeDays -gt $info.Ref.MaxAgeDays) { ' - out of date' } else { '' }
            "Retrieved $($info.Ref.LastUpdated) ($($info.AgeDays) day(s) old$old) from Microsoft Learn."
        }
}

function Start-UiBuildRefCheck {
    # Startup: ask about updating only when the file is stale, the check is on, not snoozed, and the site answers
    $u = $script:ui
    if (-not $u.ChkBuildRefOnline.Checked -or $u.BuildRefUpdating) { return }
    $info = Get-UiBuildRefInfo
    if ($info.Ref.Available -and $info.AgeDays -le $info.Ref.MaxAgeDays) { return }
    $snooze = [datetime]::MinValue
    if ($u.BuildRefSnoozeUntil -and [datetime]::TryParse([string]$u.BuildRefSnoozeUntil, [ref]$snooze) -and (Get-Date) -lt $snooze) { return }
    Start-UiBackgroundTask -Name 'BuildRefCheck' -Script {
        try { [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor [System.Net.SecurityProtocolType]::Tls12 } catch { }
        $ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36 Edg/140.0.0.0'
        try { $null = Invoke-WebRequest -Uri 'https://learn.microsoft.com/' -Method Head -UseBasicParsing -TimeoutSec 4 -UserAgent $ua -ErrorAction Stop; $true }
        catch { [bool]$_.Exception.Response }   # any HTTP answer (even 403) means the site is reachable
    } -OnDone {
        param($reachable, $err)
        if ($reachable -eq $true -and -not $script:ui.Job) { Show-UiBuildRefPrompt }
    }
}

function Show-UiBuildRefPrompt {
    $u = $script:ui
    $info = Get-UiBuildRefInfo
    $msg = if ($info.Ref.Available) {
        "The SQL Server build reference is $($info.AgeDays) days old (retrieved $($info.Ref.LastUpdated)). Patch levels " +
        "in new reports may miss the latest updates.`r`n`r`nUpdate it now from Microsoft Learn? It takes a few seconds."
    } else { "There is no SQL Server build reference, so reports show no patch levels.`r`n`r`nDownload it now from Microsoft Learn?" }

    $f = New-Object System.Windows.Forms.Form
    $f.Text = 'SQLMap - build reference'
    $f.Font = $script:UiFont
    $f.FormBorderStyle = 'FixedDialog'; $f.StartPosition = 'CenterParent'
    $f.MinimizeBox = $false; $f.MaximizeBox = $false
    $f.AutoSize = $true; $f.AutoSizeMode = 'GrowAndShrink'
    $f.Padding = New-Object System.Windows.Forms.Padding(12)
    $stack = New-UiStack
    $stack.Dock = 'None'   # docked, the stack and the auto-sized form would size each other down to nothing
    $stack.Location = New-Object System.Drawing.Point(12, 12)
    $lbl = New-UiLabel $msg
    # Fixed text width: an auto-sized dialog would otherwise shrink the label to a narrow column
    $lbl.MinimumSize = New-Object System.Drawing.Size(440, 0)
    $lbl.MaximumSize = New-Object System.Drawing.Size(440, 0)
    $stack.Controls.Add($lbl)
    $dontAsk = New-UiCheckBox "Don't ask again on this computer" $false
    $dontAsk.Margin = New-Object System.Windows.Forms.Padding(3, 12, 3, 3)
    $stack.Controls.Add($dontAsk)
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttons.FlowDirection = 'RightToLeft'; $buttons.AutoSize = $true; $buttons.Dock = 'Fill'
    $yes = New-UiButton 'Update now' 110 -Primary
    $no = New-UiButton 'Not now' 90
    $yes.DialogResult = 'Yes'; $no.DialogResult = 'No'
    $buttons.Controls.AddRange(@($no, $yes))
    $stack.Controls.Add($buttons)
    $f.Controls.Add($stack)
    $f.AcceptButton = $yes; $f.CancelButton = $no
    Initialize-UiDialog $f
    $answer = $f.ShowDialog($u.Form)
    $stopAsking = $dontAsk.Checked
    $f.Dispose()

    if ($stopAsking) { $u.ChkBuildRefOnline.Checked = $false }
    if ($answer -eq 'Yes') { Start-UiBuildRefUpdate }
    elseif (-not $stopAsking) { $u.BuildRefSnoozeUntil = (Get-Date).AddDays(7).ToString('yyyy-MM-dd') }
    Save-UiSettings
}

function Start-UiBuildRefUpdate {
    $u = $script:ui
    if ($u.BuildRefUpdating) { return }
    $u.BuildRefUpdating = $true
    $u.BtnUpdateRef.Enabled = $false
    $u.LblBuildRef.Text = 'Updating from Microsoft Learn...'
    if (-not $u.Job) { $u.LblStatus.Text = 'Updating the build reference from Microsoft Learn...' }
    Start-UiBackgroundTask -Name 'BuildRefUpdate' -Script { Update-SQLMapBuildReference -ErrorAction Stop } -OnDone {
        param($result, $err)
        $x = $script:ui
        $x.BuildRefUpdating = $false
        $x.BtnUpdateRef.Enabled = $true
        # The file was replaced by another runspace: reload it here
        & (Get-Module SQLMap) { $null = Get-SQLMapBuildReference -Reload }
        Update-UiBuildRefLabel
        if ($err -or -not $result) {
            if (-not $x.Job) { $x.LblStatus.Text = 'Build reference not updated; the current file was kept.' }
            Show-UiError "The build reference could not be updated (the current file was kept):`r`n`r`n$err`r`n`r`nThis computer may have no internet access, or need a proxy."
        }
        else {
            $x.BuildRefSnoozeUntil = $null
            Save-UiSettings
            if (-not $x.Job) { $x.LblStatus.Text = "Build reference updated: retrieved $($result.NewDate), $($result.Builds) builds. New scans use it." }
        }
    }
}

#endregion

#region Settings ---------------------------------------------------------------------------

# 2: SQL connection on and "open report" off by default (older settings files get these two defaults once)
$script:UiSettingsVersion = 2

function Save-UiSettings {
    $u = $script:ui
    try {
        $s = [ordered]@{
            SettingsVersion = $script:UiSettingsVersion
            Names = $u.TxtNames.Text; UseNames = $u.ChkNames.Checked
            File = $u.TxtFile.Text; UseFile = $u.ChkFile.Checked
            UseAd = $u.ChkAd.Checked; Domain = $u.TxtDomain.Text; NameFilter = $u.TxtNameFilter.Text; SearchBase = $u.TxtSearchBase.Text
            ActiveWithinDays = [int]$u.NumDays.Value; IncludeWorkstations = $u.ChkWorkstations.Checked
            UseSpn = $u.ChkSpn.Checked
            IpRanges = $u.TxtIp.Text; UseIp = $u.ChkIp.Checked
            UseBroadcast = $u.ChkBroadcast.Checked
            Probes = @($u.ProbeBoxes.Keys | Where-Object { $u.ProbeBoxes[$_].Checked })
            TcpPorts = $u.TxtPorts.Text; TimeoutMs = [int]$u.NumTimeout.Value; Throttle = [int]$u.NumThrottle.Value; HostTimeoutSec = [int]$u.NumHostTimeout.Value
            WinUser = $(if ($u.WinCredential) { $u.WinCredential.UserName } else { '' })
            SqlUser = $(if ($u.SqlCredential) { $u.SqlCredential.UserName } else { '' })
            OutputPath = $u.TxtOutput.Text
            Formats = @($u.FormatBoxes.Keys | Where-Object { $u.FormatBoxes[$_].Checked })
            OpenReport = $u.ChkOpenReport.Checked
            Theme = $script:UiTheme
            CheckBuildRefOnline = $u.ChkBuildRefOnline.Checked
            BuildRefSnoozeUntil = $u.BuildRefSnoozeUntil
        }
        $dir = Split-Path $script:UiSettingsPath
        if (-not (Test-Path $dir)) { $null = New-Item -Path $dir -ItemType Directory -Force }
        $s | ConvertTo-Json | Set-Content -Path $script:UiSettingsPath -Encoding UTF8
    }
    catch { }
}

function Restore-UiSettings {
    $u = $script:ui
    if (-not (Test-Path $script:UiSettingsPath)) { return }
    try {
        $s = Get-Content -Path $script:UiSettingsPath -Raw | ConvertFrom-Json
        $u.TxtNames.Text = [string]$s.Names; $u.ChkNames.Checked = [bool]$s.UseNames
        $u.TxtFile.Text = [string]$s.File; $u.ChkFile.Checked = [bool]$s.UseFile
        $u.ChkAd.Checked = [bool]$s.UseAd; $u.TxtDomain.Text = [string]$s.Domain
        if ($s.NameFilter) { $u.TxtNameFilter.Text = [string]$s.NameFilter }
        $u.TxtSearchBase.Text = [string]$s.SearchBase
        if ($s.ActiveWithinDays) { $u.NumDays.Value = [Math]::Min($u.NumDays.Maximum, [Math]::Max($u.NumDays.Minimum, [int]$s.ActiveWithinDays)) }
        $u.ChkWorkstations.Checked = [bool]$s.IncludeWorkstations
        $u.ChkSpn.Checked = [bool]$s.UseSpn
        $u.TxtIp.Text = [string]$s.IpRanges; $u.ChkIp.Checked = [bool]$s.UseIp
        $u.ChkBroadcast.Checked = [bool]$s.UseBroadcast
        # Settings saved before version 2 keep the old defaults (SQL connection off, open report on): apply the new
        # defaults once for those two, keep everything else
        $current = ([int]$s.SettingsVersion -ge $script:UiSettingsVersion)
        if ($s.Probes) {
            foreach ($k in @($u.ProbeBoxes.Keys)) {
                if ($k -eq 'SqlConnect' -and -not $current) { continue }
                $u.ProbeBoxes[$k].Checked = (@($s.Probes) -contains $k)
            }
        }
        if ($s.TcpPorts) { $u.TxtPorts.Text = [string]$s.TcpPorts }
        foreach ($pair in @(@($u.NumTimeout, $s.TimeoutMs), @($u.NumThrottle, $s.Throttle), @($u.NumHostTimeout, $s.HostTimeoutSec))) {
            if ($pair[1]) { $pair[0].Value = [Math]::Min($pair[0].Maximum, [Math]::Max($pair[0].Minimum, [int]$pair[1])) }
        }
        $u.LastWinUser = [string]$s.WinUser
        $u.LastSqlUser = [string]$s.SqlUser
        if ($s.OutputPath) { $u.TxtOutput.Text = [string]$s.OutputPath }
        if ($s.Formats) { foreach ($k in @($u.FormatBoxes.Keys)) { $u.FormatBoxes[$k].Checked = (@($s.Formats) -contains $k) } }
        if ($current) { $u.ChkOpenReport.Checked = [bool]$s.OpenReport }
        if ($s.Theme -in 'Dark', 'Light') { $u.Theme = [string]$s.Theme }
        # Online check is on unless the user turned it off ("Don't ask again" or the Options tab)
        if ($null -ne $s.CheckBuildRefOnline) { $u.ChkBuildRefOnline.Checked = [bool]$s.CheckBuildRefOnline }
        $u.BuildRefSnoozeUntil = $(if ($s.BuildRefSnoozeUntil) { [string]$s.BuildRefSnoozeUntil } else { $null })
    }
    catch { }
}

#endregion

#region Scan control -----------------------------------------------------------------------

function Get-UiScanParameters {
    # Reads the form into Invoke-SQLMapScan parameters. Throws with a user-facing message on bad input.
    $u = $script:ui
    $p = @{}
    if ($u.ChkNames.Checked) {
        $names = @($u.TxtNames.Lines | ForEach-Object { ($_ -split '#')[0].Trim() } | Where-Object { $_ })
        if ($names) { $p.ComputerName = $names }
    }
    if ($u.ChkFile.Checked) {
        $f = $u.TxtFile.Text.Trim()
        if (-not $f -or -not (Test-Path -LiteralPath $f)) { throw "Server list file not found: '$f'" }
        $p.InputFile = $f
    }
    if ($u.ChkAd.Checked -or $u.ChkSpn.Checked) {
        if ($u.TxtDomain.Text.Trim()) { $p.Domain = $u.TxtDomain.Text.Trim() }
        if ($u.TxtSearchBase.Text.Trim()) { $p.SearchBase = $u.TxtSearchBase.Text.Trim() }
    }
    if ($u.ChkAd.Checked) {
        $p.ActiveDirectory = $true
        $p.NameFilter = $(if ($u.TxtNameFilter.Text.Trim()) { $u.TxtNameFilter.Text.Trim() } else { '*' })
        $p.ActiveWithinDays = [int]$u.NumDays.Value
        if ($u.ChkWorkstations.Checked) { $p.IncludeWorkstations = $true }
    }
    if ($u.ChkSpn.Checked) { $p.SPN = $true }
    if ($u.ChkIp.Checked) {
        $ranges = @($u.TxtIp.Text -split '[,;\s]+' | Where-Object { $_ })
        if (-not $ranges) { throw 'IP ranges is checked but no range was entered.' }
        # Validate now so the user gets the error before the scan starts
        $null = & (Get-Module SQLMap) { param($r) Get-SQLMapIpRangeTarget -Range $r } $ranges
        $p.IpRange = $ranges
    }
    if ($u.ChkBroadcast.Checked) { $p.Broadcast = $true }

    $probes = @($u.ProbeBoxes.Keys | Where-Object { $u.ProbeBoxes[$_].Checked })
    if (-not $probes) { throw 'Select at least one probe on the Options tab.' }
    $p.Probe = $probes

    $ports = @()
    foreach ($t in ($u.TxtPorts.Text -split '[,;\s]+' | Where-Object { $_ })) {
        $n = 0
        if (-not [int]::TryParse($t, [ref]$n) -or $n -lt 1 -or $n -gt 65535) { throw "Invalid TCP port '$t'." }
        $ports += $n
    }
    if (-not $ports) { $ports = @(1433) }
    $p.TcpPort = $ports
    $p.TimeoutMs = [int]$u.NumTimeout.Value
    $p.Throttle = [int]$u.NumThrottle.Value
    $p.HostTimeoutSec = [int]$u.NumHostTimeout.Value

    if ($u.RadWinOther.Checked) {
        if (-not $u.WinCredential) { throw 'Set the Windows credential on the Credentials tab (or select Current user).' }
        $p.Credential = $u.WinCredential
    }
    if ($u.RadSqlLogin.Checked -and $probes -contains 'SqlConnect') {
        if (-not $u.SqlCredential) { throw 'Set the SQL login on the Credentials tab (or select Windows authentication).' }
        $p.SqlCredential = $u.SqlCredential
    }
    $p
}

function Start-UiScan {
    $u = $script:ui
    if ($u.Job) { return }
    try { $params = Get-UiScanParameters }
    catch { Show-UiError $_.Exception.Message; return }

    $formats = @($u.FormatBoxes.Keys | Where-Object { $u.FormatBoxes[$_].Checked })
    if (-not $formats) { Show-UiError 'Select at least one output format on the Output tab.'; return }

    Save-UiSettings
    $outRoot = $u.TxtOutput.Text.Trim()
    if (-not $outRoot) { $outRoot = $u.DefaultOutput }
    $runFolder = Join-Path $outRoot ('SQLMap_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try { $null = New-Item -Path $runFolder -ItemType Directory -Force }
    catch { Show-UiError "Cannot create output folder '$runFolder': $($_.Exception.Message)"; return }

    $state = [hashtable]::Synchronized(@{})
    $state.LogQueue  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
    $state.HostQueue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
    $state.CancelRequested = $false
    $params.State = $state
    $params.LogPath = Join-Path $runFolder 'SQLMap.log'

    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.ImportPSModule([string[]]@($u.ModulePath))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $scanScript = {
        param($ScanParams, $OutFolder, $Formats)
        $scan = Invoke-SQLMapScan @ScanParams
        $ScanParams.State.Phase = 'Writing reports'
        $files = $scan | Export-SQLMapReport -Path $OutFolder -Format $Formats
        [pscustomobject]@{ Scan = $scan; Files = $files }
    }
    [void]$ps.AddScript($scanScript.ToString()).AddArgument($params).AddArgument($runFolder).AddArgument($formats)

    Clear-UiResults
    $u.TxtLog.Clear()
    $u.LastScan = $null; $u.LastFiles = $null; $u.LastFolder = $runFolder
    $u.Job = @{ PS = $ps; Runspace = $rs; Handle = $ps.BeginInvoke(); State = $state; Started = Get-Date; Folder = $runFolder; Formats = $formats }
    Set-UiRunning $true
    $u.LblStatus.Text = 'Discovering targets...'
    Set-UiProgress -Indeterminate
    $u.LblProgress.Text = ''
    Update-UiSummary
    $u.Timer.Start()
}

function Stop-UiScan {
    $u = $script:ui
    if (-not $u.Job) { return }
    $u.Job.State.CancelRequested = $true
    $u.BtnCancel.Enabled = $false
    $u.LblStatus.Text = 'Cancelling... finishing the hosts in progress'
}

function Set-UiRunning {
    param([bool]$Running)
    $u = $script:ui
    $u.BtnStart.Enabled = -not $Running
    $u.BtnCancel.Enabled = $Running
    $u.BtnLoad.Enabled = -not $Running
    # The configuration stays editable during a scan (values are read when a scan starts);
    # disabling it would paint every text box light gray in dark mode.
    $u.BtnOpenReport.Enabled = (-not $Running) -and [bool]$u.LastScan
    $u.BtnOpenFolder.Enabled = (-not $Running) -and [bool]$u.LastFolder -and (Test-Path -LiteralPath $u.LastFolder)
}

function Invoke-UiTimerTick {
    $u = $script:ui
    $job = $u.Job
    if (-not $job) { $u.Timer.Stop(); return }
    $state = $job.State

    # Log lines (bounded per tick so the UI stays responsive)
    $sb = New-Object System.Text.StringBuilder
    $line = $null; $n = 0
    while ($n -lt 2000 -and $state.LogQueue.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line); $n++ }
    if ($sb.Length) { $u.TxtLog.AppendText($sb.ToString()) }

    # Finished hosts
    $hostObj = $null; $added = 0
    while ($added -lt 500 -and $state.HostQueue.TryDequeue([ref]$hostObj)) { Add-UiHostResult $hostObj; $added++ }
    if ($added) {
        Update-UiSummary
        if ($u.Tables.Hosts.Rows.Count -le 200) { Resize-UiGrids }
    }

    # Progress
    $elapsed = (Get-Date) - $job.Started
    $elapsedText = '{0:hh\:mm\:ss}' -f $elapsed
    if ($state.Phase -eq 'Scanning' -and $state.Total) {
        $done = [int]$state.Completed; $total = [int]$state.Total
        Set-UiProgress -Value $done -Maximum $total
        if (-not $job.ScanStarted) { $job.ScanStarted = Get-Date }   # discovery time is not part of the estimate
        if ($state.CancelRequested) { $u.LblProgress.Text = 'Cancelling...' }
        else {
            $u.LblStatus.Text = "Scanning: $done of $total hosts done, $($state.Running) running - elapsed $elapsedText"
            $u.LblProgress.Text = (Get-UiProgressText -Done $done -Total $total -ScanSeconds ((Get-Date) - $job.ScanStarted).TotalSeconds)
        }
    }
    elseif ($state.Phase -eq 'Discovery' -or -not $state.Phase) {
        $u.LblStatus.Text = "Discovering targets... $elapsedText"
    }
    elseif ($state.Phase -eq 'Writing reports') {
        $u.LblStatus.Text = "Writing reports... $elapsedText"
    }

    if ($job.Handle.IsCompleted) { Complete-UiScan }
}

function Complete-UiScan {
    $u = $script:ui
    $job = $u.Job
    $u.Timer.Stop()
    $result = $null; $errorText = $null
    try {
        $result = $job.PS.EndInvoke($job.Handle) | Select-Object -Last 1
        if ($job.PS.Streams.Error.Count) { $errorText = ($job.PS.Streams.Error | Select-Object -First 3 | ForEach-Object { $_.ToString() }) -join "`r`n" }
    }
    catch { $errorText = $_.Exception.InnerException.Message; if (-not $errorText) { $errorText = $_.Exception.Message } }
    finally {
        $job.PS.Dispose()
        $job.Runspace.Dispose()
        $u.Job = $null
    }
    # Drain anything left in the queues
    $line = $null
    $sb = New-Object System.Text.StringBuilder
    while ($job.State.LogQueue.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length) { $u.TxtLog.AppendText($sb.ToString()) }

    if ($result -and $result.Scan) {
        $u.LastScan = $result.Scan
        $u.LastFiles = $result.Files
        Show-UiScan $result.Scan
        $s = $result.Scan.Summary
        Set-UiProgress -Value 1 -Maximum 1
        $u.LblProgress.Text = if ($result.Scan.Cancelled) { 'Cancelled' } else { '100%' }
        $verb = if ($result.Scan.Cancelled) { 'Cancelled after' } else { 'Finished in' }
        $u.LblStatus.Text = "$verb $($result.Scan.DurationSec)s: $($s.Targets) host(s), $($s.HostsWithSql) with SQL Server, $($s.Instances) instance(s). Saved to $($job.Folder)"
        if ($u.ChkOpenReport.Checked -and $result.Files.Html -and -not $result.Scan.Cancelled) { Invoke-Item -LiteralPath $result.Files.Html }
    }
    else {
        Set-UiProgress -Value 0
        $u.LblProgress.Text = ''
        $u.LblStatus.Text = 'Scan failed.'
    }
    Set-UiRunning $false
    if ($errorText) { Show-UiError "The scan reported an error:`r`n`r`n$errorText" }
}

function Open-UiReport {
    $u = $script:ui
    if (-not $u.LastScan) { return }
    $html = $null
    if ($u.LastFiles -and $u.LastFiles.Html -and (Test-Path -LiteralPath $u.LastFiles.Html)) { $html = $u.LastFiles.Html }
    else {
        # Loaded scan, or HTML not selected as a format: render it next to the scan files
        $files = $u.LastScan | Export-SQLMapReport -Path $u.LastFolder -Format Html
        $html = $files.Html
        if (-not $u.LastFiles) { $u.LastFiles = $files } else { $u.LastFiles.Html = $html }
    }
    Invoke-Item -LiteralPath $html
}

function Import-UiScanFile {
    $u = $script:ui
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Filter = 'SQLMap scan (*.json)|*.json|All files (*.*)|*.*'
    $dlg.Title = 'Load a SQLMap scan'
    if (Test-Path -LiteralPath $u.TxtOutput.Text) { $dlg.InitialDirectory = $u.TxtOutput.Text }
    if ($dlg.ShowDialog($u.Form) -ne 'OK') { return }
    try { $scan = Import-SQLMapScan -Path $dlg.FileName }
    catch { Show-UiError $_.Exception.Message; return }
    $u.LastScan = $scan
    $u.LastFolder = Split-Path $dlg.FileName
    $base = [IO.Path]::GetFileNameWithoutExtension($dlg.FileName)
    $html = Join-Path $u.LastFolder "$base.html"
    $u.LastFiles = [pscustomobject]@{ Html = $(if (Test-Path -LiteralPath $html) { $html } else { $null }) }
    $u.TxtLog.Clear()
    Show-UiScan $scan
    $u.LblStatus.Text = "Loaded scan from $($scan.StartTime) ($($dlg.FileName))"
    Set-UiProgress -Value 0
    $u.LblProgress.Text = ''
    Set-UiRunning $false
}

function Update-UiCredentialLabels {
    $u = $script:ui
    $u.LblWinCred.Text = $(if ($u.WinCredential) { $u.WinCredential.UserName } else { '(not set)' })
    $u.LblSqlCred.Text = $(if ($u.SqlCredential) { $u.SqlCredential.UserName } else { '(not set)' })
}

#endregion

#region Main form --------------------------------------------------------------------------

function New-SQLMapMainForm {
    param(
        [Parameter(Mandatory)][string]$ModulePath,
        [Parameter(Mandatory)][string]$DefaultOutput,
        [string]$IconPath,
        # Startup progress for the console (SQLMap.ps1 passes one): receives one line per step, like SQLSecReview
        [scriptblock]$StartupProgress
    )
    # Closure: the Load/Shown handlers call it after this function has returned (it uses no $script: state)
    $startupStep = { param([string]$Text) if ($StartupProgress) { try { & $StartupProgress $Text } catch { } } }.GetNewClosure()
    & $startupStep 'Building the main window...'
    $script:ui = @{
        ModulePath = $ModulePath; DefaultOutput = $DefaultOutput; Icon = $null
        Job = $null; LastScan = $null; LastFiles = $null; LastFolder = $null
        WinCredential = $null; SqlCredential = $null; LastWinUser = ''; LastSqlUser = ''; Theme = 'Dark'
        HostObjects = New-Object System.Collections.Generic.List[object]
        InstanceObjects = New-Object System.Collections.Generic.List[object]
        Tables = New-UiTables
        BgTasks = New-Object System.Collections.Generic.List[object]   # background jobs other than the scan
        BuildRefUpdating = $false; BuildRefSnoozeUntil = $null
    }
    $u = $script:ui
    $u.StartupStep = $startupStep   # used by the Load/Shown handlers, which run after this function returns

    $form = New-Object System.Windows.Forms.Form
    $form.Text = 'SQLMap - SQL Server discovery'
    $form.Font = $script:UiFont
    $form.AutoScaleDimensions = New-Object System.Drawing.SizeF(96, 96)
    $form.AutoScaleMode = 'Dpi'
    $form.Size = New-Object System.Drawing.Size(1280, 820)
    $form.MinimumSize = New-Object System.Drawing.Size(960, 600)
    $form.StartPosition = 'CenterScreen'
    if ($IconPath -and (Test-Path -LiteralPath $IconPath)) {
        try { $u.Icon = New-Object System.Drawing.Icon($IconPath); $form.Icon = $u.Icon } catch { }
    }
    $u.Form = $form

    $split = New-Object System.Windows.Forms.SplitContainer
    $split.Dock = 'Fill'
    $split.FixedPanel = 'Panel1'
    $split.SplitterWidth = 1
    $form.Controls.Add($split)
    $u.Split = $split

    # ---- Left: configuration -------------------------------------------------------------
    & $startupStep 'Building the configuration panel (Targets, Options, Credentials and Output tabs)...'
    $left = New-Object System.Windows.Forms.TableLayoutPanel
    $left.Dock = 'Fill'
    $left.ColumnCount = 1; $left.RowCount = 2
    $left.Padding = New-Object System.Windows.Forms.Padding(6, 6, 4, 0)
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$left.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $split.Panel1.Controls.Add($left)

    $tabs = New-UiTabSet @('Targets', 'Options', 'Credentials', 'Output')
    $left.Controls.Add($tabs.Root, 0, 0)
    $u.ConfigTabs = $tabs

    # Targets tab
    $t = New-UiStack
    $u.ChkNames = New-UiCheckBox 'Computer names' $true -Bold
    $t.Controls.Add($u.ChkNames)
    $t.Controls.Add((New-UiLabel 'One per line. srv, srv\instance and srv,port are accepted. Empty = this computer.' -Muted))
    $u.TxtNames = New-UiTextBox -Multiline -Lines 4
    $t.Controls.Add($u.TxtNames)

    $u.ChkFile = New-UiCheckBox 'Server list file' -Bold
    $t.Controls.Add($u.ChkFile)
    $t.Controls.Add((New-UiLabel '.txt (one per line) or .csv with a ComputerName / Name / Server / Host column.' -Muted))
    $fileRow = New-Object System.Windows.Forms.TableLayoutPanel
    $fileRow.ColumnCount = 2; $fileRow.Dock = 'Fill'; $fileRow.AutoSize = $true
    [void]$fileRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$fileRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $u.TxtFile = New-UiTextBox
    $u.BtnFile = New-UiButton 'Browse...' 70
    $fileRow.Controls.Add($u.TxtFile, 0, 0); $fileRow.Controls.Add($u.BtnFile, 1, 0)
    $t.Controls.Add($fileRow)
    $u.FileRow = $fileRow

    $u.ChkAd = New-UiCheckBox 'Active Directory computers' -Bold
    $t.Controls.Add($u.ChkAd)
    $t.Controls.Add((New-UiLabel 'Enabled computer accounts. No RSAT needed.' -Muted))
    $u.AdGrid = New-UiGrid2
    $u.TxtDomain = New-UiTextBox
    $u.TxtNameFilter = New-UiTextBox '*'
    $u.TxtSearchBase = New-UiTextBox
    $u.NumDays = New-UiNumeric 0 3650 90
    $u.ChkWorkstations = New-UiCheckBox 'Include workstations (default: servers only)'
    Add-UiRow $u.AdGrid 'Domain (empty = current)' $u.TxtDomain
    Add-UiRow $u.AdGrid 'Name filter' $u.TxtNameFilter
    Add-UiRow $u.AdGrid 'OU (distinguished name)' $u.TxtSearchBase
    Add-UiRow $u.AdGrid 'Logged on within (days, 0 = any)' $u.NumDays
    $u.AdGrid.Controls.Add($u.ChkWorkstations)
    $u.AdGrid.SetColumnSpan($u.ChkWorkstations, 2)
    $t.Controls.Add($u.AdGrid)

    $u.ChkSpn = New-UiCheckBox 'Active Directory SPNs (MSSQLSvc)' -Bold
    $t.Controls.Add($u.ChkSpn)
    $t.Controls.Add((New-UiLabel 'Every host with a registered SQL Server SPN. Uses the domain/OU above.' -Muted))

    $u.ChkIp = New-UiCheckBox 'IP ranges' -Bold
    $t.Controls.Add($u.ChkIp)
    $t.Controls.Add((New-UiLabel '10.0.0.0/24, 10.0.0.1-10.0.0.50, 10.0.0.1-50 or single IPs; one per line.' -Muted))
    $u.TxtIp = New-UiTextBox -Multiline -Lines 3
    $t.Controls.Add($u.TxtIp)

    $u.ChkBroadcast = New-UiCheckBox 'SQL Browser broadcast (local subnet)' -Bold
    $t.Controls.Add($u.ChkBroadcast)
    $tabs.Pages[0].Controls.Add($t)

    # Options tab
    $o = New-UiStack
    $o.Controls.Add((New-UiLabel 'Probes' -Bold))
    $u.ProbeBoxes = [ordered]@{
        Ping       = New-UiCheckBox 'Ping (ICMP)' $true
        Tcp        = New-UiCheckBox 'TCP ports' $true
        Browser    = New-UiCheckBox 'SQL Server Browser (UDP 1434)' $true
        Registry   = New-UiCheckBox 'Registry (installed instances, versions, SSIS)' $true
        Service    = New-UiCheckBox 'Windows services + OS/hardware (WMI)' $true
        SqlConnect = New-UiCheckBox 'SQL connection (read-only queries: CU, databases, sizes)' $true
    }
    foreach ($k in $u.ProbeBoxes.Keys) { $u.ProbeBoxes[$k].Margin = New-Object System.Windows.Forms.Padding(12, 3, 3, 1); $o.Controls.Add($u.ProbeBoxes[$k]) }
    $o.Controls.Add((New-UiLabel 'Scan settings' -Bold))
    $og = New-UiGrid2
    $og.Margin = New-Object System.Windows.Forms.Padding(9, 0, 3, 3)
    $u.TxtPorts = New-UiTextBox '1433'
    $u.NumTimeout = New-UiNumeric 200 60000 1500 100
    $u.NumThrottle = New-UiNumeric 1 256 32
    $u.NumHostTimeout = New-UiNumeric 10 3600 300 10
    Add-UiRow $og 'SQL TCP ports' $u.TxtPorts
    Add-UiRow $og 'Probe timeout (ms)' $u.NumTimeout
    Add-UiRow $og 'Hosts in parallel' $u.NumThrottle
    Add-UiRow $og 'Max time per host (s)' $u.NumHostTimeout
    $o.Controls.Add($og)
    $o.Controls.Add((New-UiLabel 'Ports 135, 445 and 5985 are always checked to skip probes that cannot work.' -Muted))

    # Build reference (patch levels): status, online check at startup, update on demand
    $o.Controls.Add((New-UiLabel 'Build reference (patch levels)' -Bold))
    $u.LblBuildRef = New-UiLabel '' -Muted
    $u.LblBuildRef.MaximumSize = New-Object System.Drawing.Size(380, 0)
    $u.LblBuildRef.Margin = New-Object System.Windows.Forms.Padding(12, 3, 3, 2)
    $o.Controls.Add($u.LblBuildRef)
    $u.ChkBuildRefOnline = New-UiCheckBox 'At startup, check online when it is older than 30 days' $true
    $u.ChkBuildRefOnline.Margin = New-Object System.Windows.Forms.Padding(12, 3, 3, 1)
    $o.Controls.Add($u.ChkBuildRefOnline)
    $u.BtnUpdateRef = New-UiButton 'Update build reference' 170
    $u.BtnUpdateRef.Margin = New-Object System.Windows.Forms.Padding(12, 6, 3, 3)
    $o.Controls.Add($u.BtnUpdateRef)
    $tabs.Pages[1].Controls.Add($o)

    # Credentials tab
    $c = New-UiStack
    $c.Controls.Add((New-UiLabel 'Windows (registry, WMI, Active Directory)' -Bold))
    $winPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $winPanel.FlowDirection = 'TopDown'; $winPanel.AutoSize = $true; $winPanel.Dock = 'Fill'; $winPanel.WrapContents = $false
    $u.RadWinCurrent = New-UiRadio "Current user ($env:USERDOMAIN\$env:USERNAME)" $true
    $u.RadWinOther = New-UiRadio 'Other credential'
    $winRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $winRow.AutoSize = $true; $winRow.WrapContents = $false
    $u.BtnWinCred = New-UiButton 'Set...' 60
    $u.LblWinCred = New-UiLabel '(not set)' -Muted
    $winRow.Controls.AddRange(@($u.BtnWinCred, $u.LblWinCred))
    $winPanel.Controls.AddRange(@($u.RadWinCurrent, $u.RadWinOther, $winRow))
    $c.Controls.Add($winPanel)
    $c.Controls.Add((New-UiLabel 'Remote Registry always uses the current user; with another credential the registry is read through WMI.' -Muted))

    $c.Controls.Add((New-UiLabel 'SQL connection' -Bold))
    $sqlPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $sqlPanel.FlowDirection = 'TopDown'; $sqlPanel.AutoSize = $true; $sqlPanel.Dock = 'Fill'; $sqlPanel.WrapContents = $false
    $u.RadSqlWindows = New-UiRadio 'Windows authentication (current user)' $true
    $u.RadSqlLogin = New-UiRadio 'SQL login'
    $sqlRow = New-Object System.Windows.Forms.FlowLayoutPanel
    $sqlRow.AutoSize = $true; $sqlRow.WrapContents = $false
    $u.BtnSqlCred = New-UiButton 'Set...' 60
    $u.LblSqlCred = New-UiLabel '(not set)' -Muted
    $sqlRow.Controls.AddRange(@($u.BtnSqlCred, $u.LblSqlCred))
    $sqlPanel.Controls.AddRange(@($u.RadSqlWindows, $u.RadSqlLogin, $sqlRow))
    $c.Controls.Add($sqlPanel)
    $c.Controls.Add((New-UiLabel 'Passwords stay in memory only and are never saved.' -Muted))
    $tabs.Pages[2].Controls.Add($c)

    # Output tab
    $out = New-UiStack
    $out.Controls.Add((New-UiLabel 'Output folder (a subfolder is created per scan)' -Bold))
    $outRow = New-Object System.Windows.Forms.TableLayoutPanel
    $outRow.ColumnCount = 2; $outRow.Dock = 'Fill'; $outRow.AutoSize = $true
    [void]$outRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$outRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $u.TxtOutput = New-UiTextBox $DefaultOutput
    $u.BtnOutput = New-UiButton 'Browse...' 70
    $outRow.Controls.Add($u.TxtOutput, 0, 0); $outRow.Controls.Add($u.BtnOutput, 1, 0)
    $out.Controls.Add($outRow)
    $out.Controls.Add((New-UiLabel 'Formats' -Bold))
    $u.FormatBoxes = [ordered]@{
        Html = New-UiCheckBox 'HTML report' $true
        Json = New-UiCheckBox 'JSON (full scan, can be loaded again)' $true
        Csv  = New-UiCheckBox 'CSV (instances and hosts)' $true
    }
    foreach ($k in $u.FormatBoxes.Keys) { $u.FormatBoxes[$k].Margin = New-Object System.Windows.Forms.Padding(12, 3, 3, 1); $out.Controls.Add($u.FormatBoxes[$k]) }
    $u.ChkOpenReport = New-UiCheckBox 'Open the HTML report when the scan finishes' $false
    $out.Controls.Add($u.ChkOpenReport)
    $out.Controls.Add((New-UiLabel 'Reports contain client infrastructure data. Store and share them as confidential.' -Muted))
    $tabs.Pages[3].Controls.Add($out)

    # Start / Cancel
    $runBar = New-Object System.Windows.Forms.FlowLayoutPanel
    $runBar.Dock = 'Fill'; $runBar.AutoSize = $true
    $runBar.Padding = New-Object System.Windows.Forms.Padding(0, 6, 0, 6)
    $u.BtnStart = New-UiButton 'Start scan' 110 -Primary
    $u.BtnCancel = New-UiButton 'Cancel' 90
    $u.BtnCancel.Enabled = $false
    $runBar.Controls.AddRange(@($u.BtnStart, $u.BtnCancel))
    $left.Controls.Add($runBar, 0, 1)

    # ---- Right: results ------------------------------------------------------------------
    & $startupStep 'Building the results panel (Instances, Hosts and Log tabs)...'
    $right = New-Object System.Windows.Forms.TableLayoutPanel
    $right.Dock = 'Fill'
    $right.ColumnCount = 1; $right.RowCount = 5
    $right.Padding = New-Object System.Windows.Forms.Padding(8, 6, 8, 4)
    foreach ($rs in 'AutoSize', 'AutoSize', 'AutoSize', 'Percent', 'AutoSize') {
        if ($rs -eq 'Percent') { [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100))) }
        else { [void]$right.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::AutoSize))) }
    }
    $split.Panel2.Controls.Add($right)

    $u.LblStatus = New-UiLabel 'Ready. Choose targets on the left and press Start scan.' -Bold
    $u.LblStatus.AutoEllipsis = $true
    $u.LblStatus.AutoSize = $false
    $u.LblStatus.Dock = 'Fill'
    $u.LblStatus.Height = 24
    $right.Controls.Add($u.LblStatus, 0, 0)

    # Progress row: the bar, and next to it the percent and the estimated time left
    $u.Progress = New-UiProgress
    $progRow = New-Object System.Windows.Forms.TableLayoutPanel
    $progRow.ColumnCount = 2; $progRow.RowCount = 1
    $progRow.Dock = 'Fill'; $progRow.AutoSize = $true; $progRow.AutoSizeMode = 'GrowAndShrink'
    $progRow.Margin = New-Object System.Windows.Forms.Padding(0)
    [void]$progRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$progRow.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $progRow.Controls.Add($u.Progress.Track, 0, 0)
    $u.LblProgress = New-UiLabel ''
    $u.LblProgress.Anchor = 'Right'
    $u.LblProgress.Margin = New-Object System.Windows.Forms.Padding(10, 0, 3, 0)
    $progRow.Controls.Add($u.LblProgress, 1, 0)
    $right.Controls.Add($progRow, 0, 1)
    $u.MarqueeTimer = New-Object System.Windows.Forms.Timer
    $u.MarqueeTimer.Interval = 30
    $u.MarqueeTimer.Add_Tick({ $script:ui.Progress.Pos += 1.5; Update-UiProgress })

    $u.LblSummary = New-UiLabel '' -Muted
    $right.Controls.Add($u.LblSummary, 0, 2)

    $results = New-UiTabSet @('Instances', 'Hosts', 'Log')
    $u.TabInstances = $results.Buttons[0]
    $u.TabHosts = $results.Buttons[1]
    $u.GridInstances = New-UiDataGrid
    $u.GridHosts = New-UiDataGrid
    $u.GridInstances.DataSource = $u.Tables.Instances
    $u.GridHosts.DataSource = $u.Tables.Hosts
    $results.Pages[0].Controls.Add($u.GridInstances)
    $results.Pages[1].Controls.Add($u.GridHosts)
    $u.TxtLog = New-Object System.Windows.Forms.TextBox
    $u.TxtLog.Multiline = $true; $u.TxtLog.ReadOnly = $true; $u.TxtLog.ScrollBars = 'Both'; $u.TxtLog.WordWrap = $false
    $u.TxtLog.Dock = 'Fill'; $u.TxtLog.Font = $script:UiFontMono
    $u.TxtLog.MaxLength = 0
    $results.Pages[2].Controls.Add($u.TxtLog)
    $right.Controls.Add($results.Root, 0, 3)
    $u.ResultTabs = $results

    $bottom = New-Object System.Windows.Forms.FlowLayoutPanel
    $bottom.Dock = 'Fill'; $bottom.AutoSize = $true
    $u.BtnOpenReport = New-UiButton 'Open HTML report' 120
    $u.BtnOpenFolder = New-UiButton 'Open output folder' 120
    $u.BtnLoad = New-UiButton 'Load scan (JSON)...' 120
    $u.BtnOpenReport.Enabled = $false; $u.BtnOpenFolder.Enabled = $false
    $hint = New-UiLabel 'Double-click a row for details.' -Muted
    $u.BtnTheme = New-UiButton 'Light theme' 100
    $bottom.Controls.AddRange(@($u.BtnOpenReport, $u.BtnOpenFolder, $u.BtnLoad, $hint))
    $bottomGrid = New-Object System.Windows.Forms.TableLayoutPanel
    $bottomGrid.ColumnCount = 2; $bottomGrid.Dock = 'Fill'; $bottomGrid.AutoSize = $true
    $bottomGrid.Margin = New-Object System.Windows.Forms.Padding(0, 4, 0, 0)
    [void]$bottomGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$bottomGrid.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::AutoSize)))
    $bottomGrid.Controls.Add($bottom, 0, 0)
    $bottomGrid.Controls.Add($u.BtnTheme, 1, 0)
    $right.Controls.Add($bottomGrid, 0, 4)

    $u.BgTimer = New-Object System.Windows.Forms.Timer
    $u.BgTimer.Interval = 250
    $u.BgTimer.Add_Tick({ Invoke-UiBackgroundTick })
    $u.BtnUpdateRef.Add_Click({ Invoke-UiSafe { Start-UiBuildRefUpdate } })
    $u.Timer = New-Object System.Windows.Forms.Timer
    $u.Timer.Interval = 300

    # ---- Events ----------------------------------------------------------------------------
    # Unchecked sources hide their inputs (disabled text boxes cannot be drawn dark in WinForms)
    $toggle = {
        $x = $script:ui
        $x.TxtNames.Visible = $x.ChkNames.Checked
        $x.FileRow.Visible = $x.ChkFile.Checked
        $x.AdGrid.Visible = $x.ChkAd.Checked -or $x.ChkSpn.Checked
        $x.TxtIp.Visible = $x.ChkIp.Checked
        $x.BtnWinCred.Enabled = $x.RadWinOther.Checked
        $x.BtnSqlCred.Enabled = $x.RadSqlLogin.Checked
    }
    $u.Toggle = $toggle
    foreach ($ctl in $u.ChkNames, $u.ChkFile, $u.ChkAd, $u.ChkSpn, $u.ChkIp, $u.RadWinOther, $u.RadSqlLogin) { $ctl.Add_CheckedChanged($toggle) }

    $u.BtnFile.Add_Click({ Invoke-UiSafe {
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Filter = 'Server lists (*.txt;*.csv)|*.txt;*.csv|All files (*.*)|*.*'
        if ($d.ShowDialog($script:ui.Form) -eq 'OK') { $script:ui.TxtFile.Text = $d.FileName }
    } })
    $u.BtnOutput.Add_Click({ Invoke-UiSafe {
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = 'Folder where scan results are written'
        if (Test-Path -LiteralPath $script:ui.TxtOutput.Text) { $d.SelectedPath = $script:ui.TxtOutput.Text }
        if ($d.ShowDialog($script:ui.Form) -eq 'OK') { $script:ui.TxtOutput.Text = $d.SelectedPath }
    } })
    $u.BtnWinCred.Add_Click({ Invoke-UiSafe {
        $x = $script:ui
        $default = if ($x.WinCredential) { $x.WinCredential.UserName } else { $x.LastWinUser }
        $cred = Read-UiCredential -Title 'Windows credential' -UserName $default -Hint 'DOMAIN\user, used for WMI, registry (via WMI) and AD queries.'
        if ($cred) { $x.WinCredential = $cred; Update-UiCredentialLabels }
    } })
    $u.BtnSqlCred.Add_Click({ Invoke-UiSafe {
        $x = $script:ui
        $default = if ($x.SqlCredential) { $x.SqlCredential.UserName } else { $x.LastSqlUser }
        $cred = Read-UiCredential -Title 'SQL login' -UserName $default -Hint 'SQL Server authentication login (read-only queries).'
        if ($cred) { $x.SqlCredential = $cred; Update-UiCredentialLabels }
    } })

    $u.BtnStart.Add_Click({ Invoke-UiSafe { Start-UiScan } })
    $u.BtnCancel.Add_Click({ Invoke-UiSafe { Stop-UiScan } })
    $u.BtnOpenReport.Add_Click({ Invoke-UiSafe { Open-UiReport } })
    $u.BtnOpenFolder.Add_Click({ Invoke-UiSafe { if ($script:ui.LastFolder) { Invoke-Item -LiteralPath $script:ui.LastFolder } } })
    $u.BtnLoad.Add_Click({ Invoke-UiSafe { Import-UiScanFile } })
    $u.BtnTheme.Add_Click({ Invoke-UiSafe { Switch-UiTheme } })
    $u.Timer.Add_Tick({ Invoke-UiSafe { Invoke-UiTimerTick } })

    $hideIdx = { param($s, $e) if ($s.Columns['Idx']) { $s.Columns['Idx'].Visible = $false } }
    $u.GridInstances.Add_DataBindingComplete($hideIdx)
    $u.GridHosts.Add_DataBindingComplete($hideIdx)
    Set-UiGridColors $u.GridInstances
    Set-UiGridColors $u.GridHosts
    $u.GridInstances.Add_CellDoubleClick({ param($s, $e) Invoke-UiSafe {
        if ($e.RowIndex -lt 0) { return }
        $idx = [int]$s.Rows[$e.RowIndex].Cells['Idx'].Value
        $i = $script:ui.InstanceObjects[$idx]
        Show-UiDetail -Title "$($i.SqlInstance) ($($i.ServiceType))" -Text (Format-UiDetail $i -Kind Instance)
    } })
    $u.GridHosts.Add_CellDoubleClick({ param($s, $e) Invoke-UiSafe {
        if ($e.RowIndex -lt 0) { return }
        $idx = [int]$s.Rows[$e.RowIndex].Cells['Idx'].Value
        $h = $script:ui.HostObjects[$idx]
        Show-UiDetail -Title $h.ComputerName -Text (Format-UiDetail $h -Kind Host)
    } })

    $form.Add_Load({ Invoke-UiSafe {
        $x = $script:ui
        & $x.StartupStep 'Loading settings and applying the theme...'
        Restore-UiSettings
        & $x.Toggle
        Update-UiCredentialLabels
        Update-UiSummary
        Update-UiBuildRefLabel
        # Dark by default; the saved choice wins
        Set-UiTheme $x.Form $x.Theme
        $x.BtnTheme.Text = $(if ($script:UiTheme -eq 'Dark') { 'Light theme' } else { 'Dark theme' })
        # Left panel width scaled to the screen DPI
        $g = $x.Form.CreateGraphics()
        try { $x.Split.SplitterDistance = [int](430 * $g.DpiX / 96) } finally { $g.Dispose() }
        & $x.StartupStep 'Opening the window...'
    } })
    $form.Add_Shown({
        & $script:ui.StartupStep 'SQLMap is open. Keep this console window open: closing it closes the application.'
        Invoke-UiSafe { Start-UiBuildRefCheck }   # background; asks only when the reference is out of date
    })
    $form.Add_FormClosing({ param($s, $e)
        $x = $script:ui
        if ($x.Job) {
            $answer = [System.Windows.Forms.MessageBox]::Show($x.Form, 'A scan is running. Stop it and close SQLMap?', 'SQLMap', 'YesNo', 'Question')
            if ($answer -ne 'Yes') { $e.Cancel = $true; return }
            $x.Timer.Stop()
            $x.Job.State.CancelRequested = $true
            try { [void]$x.Job.PS.BeginStop($null, $null) } catch { }
        }
        $x.BgTimer.Stop()
        foreach ($t in @($x.BgTasks.ToArray())) { try { [void]$t.PS.BeginStop($null, $null) } catch { } }
        Save-UiSettings
    })
    $form.AcceptButton = $null
    $u
}

#endregion
