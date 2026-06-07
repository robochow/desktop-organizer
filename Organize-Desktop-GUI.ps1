<#
.SYNOPSIS
    A WPF (windowed) front end for the Desktop Organizer.

.DESCRIPTION
    Opens a dark-themed window over the exact same engine the console scripts use
    (DesktopOrganizer.Engine.ps1). Three tabs, each preview-first and undoable:

      * Organize Files     - sort loose files into category folders
      * Consolidate Folders - merge obviously redundant folders (opt-in)
      * Clean Names        - tidy messy file names (Title Case, de-dupe markers)

    Nothing is moved, merged or renamed until you tick the rows you want and click
    the action button. Every run is logged, so "Undo Last Run" reverses whichever
    operation you did last - organize, consolidate or rename.

.NOTES
    Requires Windows (WPF). Designed for Windows PowerShell 5.1 (STA by default).
    If started from a non-STA host it relaunches itself STA automatically.
#>

[CmdletBinding()]
param(
    [string] $DesktopPath,
    [string] $LogDirectory
)

$ErrorActionPreference = 'Stop'

# --- Ensure we are running in a single-threaded apartment (required by WPF) ------
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne [System.Threading.ApartmentState]::STA) {
    $winPs = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $winPs) {
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-STA','-WindowStyle','Hidden','-File',"`"$PSCommandPath`"")
        if ($DesktopPath)  { $argList += @('-DesktopPath', "`"$DesktopPath`"") }
        if ($LogDirectory) { $argList += @('-LogDirectory', "`"$LogDirectory`"") }
        Start-Process -FilePath $winPs -ArgumentList $argList | Out-Null
        return
    }
}

# --- Hide the console window so nothing flashes behind the GUI --------------------
try {
    if (-not ('DesktopOrganizer.NativeWin' -as [type])) {
        Add-Type -Namespace 'DesktopOrganizer' -Name 'NativeWin' -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32.dll")]
public static extern System.IntPtr GetConsoleWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool ShowWindow(System.IntPtr hWnd, int nCmdShow);
'@
    }
    $consoleHandle = [DesktopOrganizer.NativeWin]::GetConsoleWindow()
    if ($consoleHandle -ne [System.IntPtr]::Zero) {
        [void][DesktopOrganizer.NativeWin]::ShowWindow($consoleHandle, 0)  # 0 = SW_HIDE
    }
} catch { }

# --- Shared engine + WPF assemblies ----------------------------------------------
. (Join-Path $PSScriptRoot 'DesktopOrganizer.Engine.ps1')
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Data | Out-Null

$script:Config       = Get-DesktopOrganizerConfig
$script:DesktopPath  = if ($DesktopPath) { Resolve-DesktopPath -Override $DesktopPath } else { Resolve-DesktopPath }
$script:LogDirectory = if ($LogDirectory) { $LogDirectory } else { $script:Config.DefaultLogDirectory }

# ----------------------------------------------------------------------------------
# UI definition (XAML). Dark theme, padded, Segoe UI, three tabs.
# ----------------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Desktop Organizer" Height="720" Width="980"
        WindowStartupLocation="CenterScreen"
        Background="#FF1E1E1E" FontFamily="Segoe UI" FontSize="13"
        TextElement.Foreground="#FFE6E6E6">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Setter Property="Background" Value="#FF333337"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#FF3E3E42"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FF0E639C"/>
      <Setter Property="BorderBrush" Value="#FF0E639C"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center" Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="#FF1177BB"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Setter Property="Margin" Value="0,3,16,3"/>
      <Setter Property="VerticalContentAlignment" Value="Center"/>
    </Style>
    <Style TargetType="GroupBox">
      <Setter Property="Foreground" Value="#FFCFCFCF"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
      <Setter Property="Margin" Value="0,0,0,12"/>
      <Setter Property="Padding" Value="12,8"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#FFCFCFCF"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="brd" Margin="0,0,4,0" Padding="16,8" CornerRadius="4,4,0,0" Background="#FF2A2A2C" BorderBrush="#FF3F3F46" BorderThickness="1,1,1,0">
              <ContentPresenter ContentSource="Header" HorizontalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="brd" Property="Background" Value="#FF0E639C"/>
                <Setter Property="Foreground" Value="#FFFFFFFF"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="brd" Property="Background" Value="#FF3E3E42"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="TabControl">
      <Setter Property="Background" Value="#FF1E1E1E"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
    </Style>
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#FF1E1E1E"/>
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
      <Setter Property="RowBackground" Value="#FF1E1E1E"/>
      <Setter Property="AlternatingRowBackground" Value="#FF252528"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#FF2D2D30"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="HeadersVisibility" Value="Column"/>
    </Style>
    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#FF2D2D30"/>
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Padding" Value="10,7"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
      <Setter Property="BorderThickness" Value="0,0,1,1"/>
    </Style>
    <Style TargetType="DataGridCell">
      <Setter Property="BorderBrush" Value="Transparent"/>
      <Setter Property="Padding" Value="8,5"/>
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Style.Triggers>
        <Trigger Property="IsSelected" Value="True">
          <Setter Property="Background" Value="#FF094771"/>
          <Setter Property="Foreground" Value="#FFFFFFFF"/>
        </Trigger>
      </Style.Triggers>
    </Style>
    <Style x:Key="Hint" TargetType="TextBlock">
      <Setter Property="Foreground" Value="#FFAFAFAF"/>
      <Setter Property="Margin" Value="0,0,0,8"/>
      <Setter Property="TextWrapping" Value="Wrap"/>
    </Style>
  </Window.Resources>

  <DockPanel Margin="16">
    <!-- Header -->
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
      <TextBlock Text="Desktop Organizer" FontSize="22" FontWeight="SemiBold" Foreground="#FFFFFFFF"/>
      <TextBlock x:Name="PathText" Foreground="#FFAFAFAF" Margin="0,2,0,0"/>
    </StackPanel>

    <!-- Shared bottom bar: Undo + status -->
    <Border DockPanel.Dock="Bottom" Background="#FF252526" BorderBrush="#FF3F3F46" BorderThickness="1" CornerRadius="4" Margin="0,12,0,0" Padding="10,6">
      <DockPanel>
        <Button x:Name="UndoButton" DockPanel.Dock="Right" Style="{StaticResource Btn}" Content="Undo Last Run" Margin="8,0,0,0"/>
        <TextBlock x:Name="StatusText" VerticalAlignment="Center" Text="Ready." Foreground="#FFCFCFCF"/>
      </DockPanel>
    </Border>

    <TabControl x:Name="Tabs" Padding="0,12,0,0">
      <!-- ============================ Organize Files ============================ -->
      <TabItem Header="Organize Files">
        <DockPanel Margin="4,12,4,4">
          <GroupBox DockPanel.Dock="Top" Header="Settings">
            <StackPanel>
              <TextBlock Text="Categories to organize" Style="{StaticResource Hint}"/>
              <WrapPanel x:Name="CategoryPanel"/>
              <CheckBox x:Name="ScreenshotByMonthCheck" Margin="0,10,0,0" Content="Group screenshots into month subfolders (Screenshots\yyyy-MM)"/>
            </StackPanel>
          </GroupBox>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="ScanButton"     Style="{StaticResource BtnAccent}" Content="Scan"/>
            <Button x:Name="OrganizeButton" Style="{StaticResource BtnAccent}" Content="Organize Now" IsEnabled="False"/>
            <Separator Width="1" Background="#FF3F3F46" Margin="6,2,10,2"/>
            <Button x:Name="OrgCheckAll"   Style="{StaticResource Btn}" Content="Check all"/>
            <Button x:Name="OrgUncheckAll" Style="{StaticResource Btn}" Content="Uncheck all"/>
          </StackPanel>
          <DataGrid x:Name="OrgGrid">
            <DataGrid.Columns>
              <DataGridCheckBoxColumn Header="Move?" Binding="{Binding Include}" Width="60"/>
              <DataGridTextColumn Header="File Name" Binding="{Binding FileName}" Width="2*" IsReadOnly="True"/>
              <DataGridTextColumn Header="Current Location" Binding="{Binding Location}" Width="3*" IsReadOnly="True"/>
              <DataGridTextColumn Header="Destination Category" Binding="{Binding Category}" Width="2*" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>

      <!-- ========================== Consolidate Folders ========================= -->
      <TabItem Header="Consolidate Folders">
        <DockPanel Margin="4,12,4,4">
          <StackPanel DockPanel.Dock="Top">
            <TextBlock Style="{StaticResource Hint}"
              Text="Finds obviously redundant folders (e.g. 'Assorted Pictures' + 'More Random Pics' + 'Pictures') and suggests merging them. System and app folders (and anything containing programs) are never touched. Approve each merge with its checkbox - nothing merges automatically."/>
            <CheckBox x:Name="IncludeFoldersCheck" Content="Include folders in the scan (off by default)" Margin="0,0,0,6"/>
          </StackPanel>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="ScanFoldersButton" Style="{StaticResource BtnAccent}" Content="Scan Folders"/>
            <Button x:Name="ConsolidateButton" Style="{StaticResource BtnAccent}" Content="Consolidate Checked" IsEnabled="False"/>
            <Separator Width="1" Background="#FF3F3F46" Margin="6,2,10,2"/>
            <Button x:Name="FolCheckAll"   Style="{StaticResource Btn}" Content="Check all"/>
            <Button x:Name="FolUncheckAll" Style="{StaticResource Btn}" Content="Uncheck all"/>
          </StackPanel>
          <DataGrid x:Name="FolderGrid">
            <DataGrid.Columns>
              <DataGridCheckBoxColumn Header="Merge?" Binding="{Binding Include}" Width="65"/>
              <DataGridTextColumn Header="Source Folder" Binding="{Binding SourceFolder}" Width="3*" IsReadOnly="True"/>
              <DataGridTextColumn Header="Files" Binding="{Binding FileCount}" Width="70" IsReadOnly="True"/>
              <DataGridTextColumn Header="Consolidate Into" Binding="{Binding TargetFolder}" Width="2*" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>

      <!-- ============================== Clean Names ============================= -->
      <TabItem Header="Clean Names">
        <DockPanel Margin="4,12,4,4">
          <TextBlock DockPanel.Dock="Top" Style="{StaticResource Hint}"
            Text="Proposes tidier names: fixes 'New folder', ALL CAPS, double spaces, underscores, random numbers and trailing (1) (2) copies, using Title Case. Extensions are left untouched. Approve each rename with its checkbox."/>
          <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
            <Button x:Name="ScanNamesButton" Style="{StaticResource BtnAccent}" Content="Scan Names"/>
            <Button x:Name="RenameButton"    Style="{StaticResource BtnAccent}" Content="Rename Checked" IsEnabled="False"/>
            <Separator Width="1" Background="#FF3F3F46" Margin="6,2,10,2"/>
            <Button x:Name="NameCheckAll"   Style="{StaticResource Btn}" Content="Check all"/>
            <Button x:Name="NameUncheckAll" Style="{StaticResource Btn}" Content="Uncheck all"/>
          </StackPanel>
          <DataGrid x:Name="NameGrid">
            <DataGrid.Columns>
              <DataGridCheckBoxColumn Header="Rename?" Binding="{Binding Include}" Width="70"/>
              <DataGridTextColumn Header="Old Name" Binding="{Binding OldName}" Width="*" IsReadOnly="True"/>
              <DataGridTextColumn Header="New Name" Binding="{Binding NewName}" Width="*" IsReadOnly="True"/>
            </DataGrid.Columns>
          </DataGrid>
        </DockPanel>
      </TabItem>
    </TabControl>
  </DockPanel>
</Window>
'@

# ----------------------------------------------------------------------------------
# Build the window
# ----------------------------------------------------------------------------------
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

foreach ($n in 'PathText','CategoryPanel','ScreenshotByMonthCheck','ScanButton','OrganizeButton',
               'OrgCheckAll','OrgUncheckAll','OrgGrid','IncludeFoldersCheck','ScanFoldersButton',
               'ConsolidateButton','FolCheckAll','FolUncheckAll','FolderGrid','ScanNamesButton',
               'RenameButton','NameCheckAll','NameUncheckAll','NameGrid','UndoButton','StatusText','Tabs') {
    Set-Variable -Name $n -Value $window.FindName($n)
}

$PathText.Text = "Desktop: $script:DesktopPath"

# Category on/off checkboxes (generated from the engine's category list).
$script:CategoryChecks = @{}
foreach ($cat in $script:Config.Categories) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $cat; $cb.IsChecked = $true
    [void]$CategoryPanel.Children.Add($cb)
    $script:CategoryChecks[$cat] = $cb
}

# --- Backing DataTables (reliable two-way checkbox binding) ----------------------
function New-Table([string[]]$cols) {
    $t = New-Object System.Data.DataTable
    [void]$t.Columns.Add('Include', [bool])
    foreach ($c in $cols) {
        $type = if ($c -eq 'FileCount') { [int] } else { [string] }
        [void]$t.Columns.Add($c, $type)
    }
    # Unary comma stops PowerShell from unrolling the DataTable to its (zero) rows,
    # which would otherwise return $null.
    return ,$t
}
$script:OrgTable    = New-Table @('FileName','Location','Category','Source','Dest')
$script:FolderTable = New-Table @('SourceFolder','FileCount','TargetFolder','SourcePath','TargetPath')
$script:NameTable   = New-Table @('OldName','NewName','Source','Dest')
$OrgGrid.ItemsSource    = $script:OrgTable.DefaultView
$FolderGrid.ItemsSource = $script:FolderTable.DefaultView
$NameGrid.ItemsSource   = $script:NameTable.DefaultView

function Set-Status([string]$text) {
    $StatusText.Text = $text
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
}
function Set-AllChecked($table, [bool]$value, $grid) {
    foreach ($row in $table.Rows) { $row['Include'] = $value }
    $table.AcceptChanges(); $grid.Items.Refresh()
}
function Get-EnabledCategories {
    @($script:Config.Categories | Where-Object { $script:CategoryChecks[$_].IsChecked })
}
function Confirm-Action([string]$message, [string]$title) {
    return ([System.Windows.MessageBox]::Show($message, $title, 'YesNo', 'Question') -eq 'Yes')
}

# ----------------------------------------------------------------------------------
# Organize Files tab
# ----------------------------------------------------------------------------------
function Invoke-Scan {
    try {
        Set-Status 'Scanning the Desktop...'
        $plan = New-OrganizePlan -DesktopPath $script:DesktopPath `
                    -EnabledCategories (Get-EnabledCategories) `
                    -ScreenshotByMonth:($ScreenshotByMonthCheck.IsChecked -eq $true) -Config $script:Config
        $script:OrgTable.Rows.Clear()
        foreach ($item in $plan) {
            $r = $script:OrgTable.NewRow()
            $r['Include']=$true; $r['FileName']=$item.FileName; $r['Location']=Split-Path -Parent $item.Source
            $r['Category']=$item.Category; $r['Source']=$item.Source; $r['Dest']=$item.Destination
            $script:OrgTable.Rows.Add($r)
        }
        $count = $script:OrgTable.Rows.Count
        $OrganizeButton.IsEnabled = ($count -gt 0)
        if ($count -eq 0) { Set-Status 'Nothing to organize - no loose files match the current settings.' }
        else { Set-Status "Previewing $count file(s). Untick any you want to keep, then click Organize Now." }
    } catch { Set-Status "Scan failed: $($_.Exception.Message)" }
}
function Invoke-Organize {
    try {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($row in $script:OrgTable.Rows) {
            if ([bool]$row['Include']) {
                $items.Add([pscustomobject]@{ Category=[string]$row['Category']; Source=[string]$row['Source']; Destination=[string]$row['Dest'] })
            }
        }
        if ($items.Count -eq 0) { Set-Status 'No files are checked - nothing to move.'; return }
        if (-not (Confirm-Action "Move $($items.Count) file(s) into their category folders?`n`nNothing is overwritten, and the run is logged so you can undo it." 'Confirm organize')) {
            Set-Status 'Cancelled - nothing was moved.'; return
        }
        Set-Status "Moving $($items.Count) file(s)..."
        $res = Invoke-OrganizePlan -Plan $items.ToArray() -DesktopPath $script:DesktopPath -LogDirectory $script:LogDirectory
        Set-Status ("{0} files moved, {1} errors.  Log: {2}" -f $res.MovedCount, $res.FailedCount, $res.LogPath)
        Show-FailureDetails $res.Failures
        Invoke-Scan
    } catch { Set-Status "Organize failed: $($_.Exception.Message)" }
}

# ----------------------------------------------------------------------------------
# Consolidate Folders tab
# ----------------------------------------------------------------------------------
function Invoke-ScanFolders {
    try {
        if ($IncludeFoldersCheck.IsChecked -ne $true) {
            Set-Status "Tick 'Include folders in the scan' first - folder consolidation is off by default."
            $script:FolderTable.Rows.Clear(); $ConsolidateButton.IsEnabled = $false; return
        }
        Set-Status 'Scanning folders for redundant groups...'
        $plan = New-FolderConsolidationPlan -DesktopPath $script:DesktopPath -Config $script:Config
        $script:FolderTable.Rows.Clear()
        foreach ($item in $plan) {
            $r = $script:FolderTable.NewRow()
            $r['Include']=$true; $r['SourceFolder']=$item.SourceFolder; $r['FileCount']=$item.FileCount
            $r['TargetFolder']=$item.TargetFolder; $r['SourcePath']=$item.SourceFolderPath; $r['TargetPath']=$item.TargetFolderPath
            $script:FolderTable.Rows.Add($r)
        }
        $count = $script:FolderTable.Rows.Count
        $ConsolidateButton.IsEnabled = ($count -gt 0)
        if ($count -eq 0) { Set-Status 'No redundant folder groups found.' }
        else { Set-Status "Found $count folder(s) to merge. Untick any to keep, then click Consolidate Checked." }
    } catch { Set-Status "Folder scan failed: $($_.Exception.Message)" }
}
function Invoke-Consolidate {
    try {
        $approved = New-Object System.Collections.Generic.List[object]
        foreach ($row in $script:FolderTable.Rows) {
            if ([bool]$row['Include']) {
                $approved.Add([pscustomobject]@{
                    SourceFolderPath=[string]$row['SourcePath']; TargetFolderPath=[string]$row['TargetPath']; TargetFolder=[string]$row['TargetFolder'] })
            }
        }
        if ($approved.Count -eq 0) { Set-Status 'No folders are checked - nothing to merge.'; return }
        if (-not (Confirm-Action "Merge $($approved.Count) folder(s) into their target folders?`n`nFiles move (never overwriting); emptied source folders are removed. The run is logged so you can undo it." 'Confirm consolidate')) {
            Set-Status 'Cancelled - nothing was merged.'; return
        }
        Set-Status 'Merging folders...'
        $expanded = Expand-FolderConsolidation -Approved $approved.ToArray() -Config $script:Config
        $res = Invoke-OrganizerMovePlan -Plan $expanded.Moves -DesktopPath $script:DesktopPath `
                    -LogDirectory $script:LogDirectory -Operation 'consolidate' -RemoveEmptyFolders $expanded.RemoveFolders
        Set-Status ("{0} files moved into {1} folder(s), {2} errors." -f $res.MovedCount, $res.RemovedFolders.Count, $res.FailedCount)
        Show-FailureDetails $res.Failures
        Invoke-ScanFolders
    } catch { Set-Status "Consolidate failed: $($_.Exception.Message)" }
}

# ----------------------------------------------------------------------------------
# Clean Names tab
# ----------------------------------------------------------------------------------
function Invoke-ScanNames {
    try {
        Set-Status 'Scanning file names...'
        $plan = New-RenamePlan -DesktopPath $script:DesktopPath -Config $script:Config
        $script:NameTable.Rows.Clear()
        foreach ($item in $plan) {
            $r = $script:NameTable.NewRow()
            $r['Include']=$true; $r['OldName']=$item.OldName; $r['NewName']=$item.NewName
            $r['Source']=$item.Source; $r['Dest']=$item.Destination
            $script:NameTable.Rows.Add($r)
        }
        $count = $script:NameTable.Rows.Count
        $RenameButton.IsEnabled = ($count -gt 0)
        if ($count -eq 0) { Set-Status 'All file names already look clean.' }
        else { Set-Status "Proposing $count rename(s). Untick any to keep, then click Rename Checked." }
    } catch { Set-Status "Name scan failed: $($_.Exception.Message)" }
}
function Invoke-Rename {
    try {
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($row in $script:NameTable.Rows) {
            if ([bool]$row['Include']) {
                $items.Add([pscustomobject]@{ Category='Rename'; Source=[string]$row['Source']; Destination=[string]$row['Dest'] })
            }
        }
        if ($items.Count -eq 0) { Set-Status 'No files are checked - nothing to rename.'; return }
        if (-not (Confirm-Action "Rename $($items.Count) file(s)?`n`nExtensions are kept; nothing is overwritten; the run is logged so you can undo it." 'Confirm rename')) {
            Set-Status 'Cancelled - nothing was renamed.'; return
        }
        Set-Status "Renaming $($items.Count) file(s)..."
        $res = Invoke-OrganizerMovePlan -Plan $items.ToArray() -DesktopPath $script:DesktopPath -LogDirectory $script:LogDirectory -Operation 'rename'
        Set-Status ("{0} files renamed, {1} errors." -f $res.MovedCount, $res.FailedCount)
        Show-FailureDetails $res.Failures
        Invoke-ScanNames
    } catch { Set-Status "Rename failed: $($_.Exception.Message)" }
}

# ----------------------------------------------------------------------------------
# Shared: failures dialog + Undo
# ----------------------------------------------------------------------------------
function Show-FailureDetails($failures) {
    if (-not $failures -or $failures.Count -eq 0) { return }
    $msg = ($failures | ForEach-Object { "- $($_.FileName): $($_.Error)" }) -join "`n"
    [void][System.Windows.MessageBox]::Show("Some items could not be processed (likely open/in use):`n`n$msg", 'Some actions failed', 'OK', 'Warning')
}
function Invoke-Undo {
    try {
        $logFile = Get-LatestOrganizeLog -LogDirectory $script:LogDirectory
        if (-not $logFile) { Set-Status 'Nothing to undo - no previous run was found.'; return }
        $preview = Get-OrganizeUndoPlan -LogFile $logFile
        if (-not (Confirm-Action ("Undo the last run?`n`nThis restores {0} item(s). {1} will be skipped (already moved or the spot is taken)." -f $preview.Restorable.Count, $preview.Skips.Count) 'Confirm undo')) {
            Set-Status 'Cancelled - nothing was changed.'; return
        }
        Set-Status 'Undoing the last run...'
        $res = Invoke-OrganizeUndo -LogFile $logFile
        Set-Status ("Undo complete. {0} restored, {1} skipped." -f $res.Restored, $res.Skipped)
        # Refresh whichever previews are populated.
        Invoke-Scan
        if ($IncludeFoldersCheck.IsChecked -eq $true) { Invoke-ScanFolders }
        if ($script:NameTable.Rows.Count -gt 0) { Invoke-ScanNames }
    } catch { Set-Status "Undo failed: $($_.Exception.Message)" }
}

# --- Wire events ------------------------------------------------------------------
$ScanButton.Add_Click({ Invoke-Scan })
$OrganizeButton.Add_Click({ Invoke-Organize })
$OrgCheckAll.Add_Click({ Set-AllChecked $script:OrgTable $true $OrgGrid })
$OrgUncheckAll.Add_Click({ Set-AllChecked $script:OrgTable $false $OrgGrid })

$ScanFoldersButton.Add_Click({ Invoke-ScanFolders })
$ConsolidateButton.Add_Click({ Invoke-Consolidate })
$FolCheckAll.Add_Click({ Set-AllChecked $script:FolderTable $true $FolderGrid })
$FolUncheckAll.Add_Click({ Set-AllChecked $script:FolderTable $false $FolderGrid })

$ScanNamesButton.Add_Click({ Invoke-ScanNames })
$RenameButton.Add_Click({ Invoke-Rename })
$NameCheckAll.Add_Click({ Set-AllChecked $script:NameTable $true $NameGrid })
$NameUncheckAll.Add_Click({ Set-AllChecked $script:NameTable $false $NameGrid })

$UndoButton.Add_Click({ Invoke-Undo })

# Auto-scan the Organize tab on open.
$window.Add_Loaded({ Invoke-Scan })

[void]$window.ShowDialog()
