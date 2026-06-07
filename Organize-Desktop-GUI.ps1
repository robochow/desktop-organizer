<#
.SYNOPSIS
    A WPF (windowed) front end for the Desktop Organizer.

.DESCRIPTION
    Opens a dark-themed window over the exact same engine the console scripts use
    (DesktopOrganizer.Engine.ps1). From here you can:
      * Scan the Desktop and preview every planned move in a grid
      * Tick / untick individual files to include or exclude them
      * Toggle whole categories on or off, and group screenshots by month
      * Organize the checked files (never overwriting; every run is logged)
      * Undo the most recent run

    No moving, logging or safety logic is reimplemented here - the window is purely
    a front end. Launch it with a double-click via the shortcut from
    Create-Shortcut.ps1, or run it directly with Windows PowerShell.

.NOTES
    Requires Windows (WPF). Designed for Windows PowerShell 5.1, which is present on
    every modern Windows install and runs single-threaded-apartment (STA) by
    default - exactly what WPF needs. If started from a non-STA host this script
    relaunches itself STA automatically.
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
# Standard P/Invoke (Add-Type is a core PowerShell cmdlet - nothing extra installed).
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
# UI definition (XAML). Dark theme, padded, Segoe UI.
# ----------------------------------------------------------------------------------
$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Desktop Organizer" Height="640" Width="940"
        WindowStartupLocation="CenterScreen"
        Background="#FF1E1E1E" FontFamily="Segoe UI" FontSize="13"
        TextElement.Foreground="#FFE6E6E6">
  <Window.Resources>
    <!-- Base button -->
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Setter Property="Background" Value="#FF333337"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="14,7"/>
      <Setter Property="Margin" Value="0,0,8,0"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="SnapsToDevicePixels" Value="True"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#FF3E3E42"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- Accent (primary) button -->
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#FF0E639C"/>
      <Setter Property="BorderBrush" Value="#FF0E639C"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" CornerRadius="4" Background="{TemplateBinding Background}"
                    BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                Margin="{TemplateBinding Padding}"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="b" Property="Background" Value="#FF1177BB"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter Property="Opacity" Value="0.45"/>
              </Trigger>
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
    <!-- DataGrid + parts -->
    <Style TargetType="DataGrid">
      <Setter Property="Background" Value="#FF1E1E1E"/>
      <Setter Property="Foreground" Value="#FFE6E6E6"/>
      <Setter Property="BorderBrush" Value="#FF3F3F46"/>
      <Setter Property="RowBackground" Value="#FF1E1E1E"/>
      <Setter Property="AlternatingRowBackground" Value="#FF252528"/>
      <Setter Property="GridLinesVisibility" Value="Horizontal"/>
      <Setter Property="HorizontalGridLinesBrush" Value="#FF2D2D30"/>
      <Setter Property="RowHeaderWidth" Value="0"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="AutoGenerateColumns" Value="False"/>
      <Setter Property="CanUserAddRows" Value="False"/>
      <Setter Property="CanUserDeleteRows" Value="False"/>
      <Setter Property="SelectionMode" Value="Extended"/>
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
  </Window.Resources>

  <DockPanel Margin="16">
    <!-- Header -->
    <StackPanel DockPanel.Dock="Top" Margin="0,0,0,12">
      <TextBlock Text="Desktop Organizer" FontSize="22" FontWeight="SemiBold" Foreground="#FFFFFFFF"/>
      <TextBlock x:Name="PathText" Foreground="#FFAFAFAF" Margin="0,2,0,0"/>
    </StackPanel>

    <!-- Settings -->
    <GroupBox DockPanel.Dock="Top" Header="Settings">
      <StackPanel>
        <TextBlock Text="Categories to organize" Foreground="#FFAFAFAF" Margin="0,0,0,4"/>
        <WrapPanel x:Name="CategoryPanel"/>
        <CheckBox x:Name="ScreenshotByMonthCheck" Margin="0,10,0,0"
                  Content="Group screenshots into month subfolders (Screenshots\yyyy-MM)"/>
      </StackPanel>
    </GroupBox>

    <!-- Toolbar -->
    <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
      <Button x:Name="ScanButton"     Style="{StaticResource BtnAccent}" Content="Scan"/>
      <Button x:Name="OrganizeButton" Style="{StaticResource BtnAccent}" Content="Organize Now" IsEnabled="False"/>
      <Button x:Name="UndoButton"     Style="{StaticResource Btn}"       Content="Undo Last Run"/>
      <Separator Width="1" Background="#FF3F3F46" Margin="6,2,10,2"/>
      <Button x:Name="CheckAllButton"   Style="{StaticResource Btn}" Content="Check all"/>
      <Button x:Name="UncheckAllButton" Style="{StaticResource Btn}" Content="Uncheck all"/>
    </StackPanel>

    <!-- Status bar -->
    <Border DockPanel.Dock="Bottom" Background="#FF252526" BorderBrush="#FF3F3F46"
            BorderThickness="1" CornerRadius="4" Margin="0,12,0,0" Padding="10,6">
      <TextBlock x:Name="StatusText" Text="Ready. Click Scan to preview what would move." Foreground="#FFCFCFCF"/>
    </Border>

    <!-- Preview grid -->
    <DataGrid x:Name="Grid">
      <DataGrid.Columns>
        <DataGridCheckBoxColumn Header="Move?" Binding="{Binding Include}" Width="60"/>
        <DataGridTextColumn Header="File Name" Binding="{Binding FileName}" Width="2*" IsReadOnly="True"/>
        <DataGridTextColumn Header="Current Location" Binding="{Binding Location}" Width="3*" IsReadOnly="True"/>
        <DataGridTextColumn Header="Destination Category" Binding="{Binding Category}" Width="2*" IsReadOnly="True"/>
      </DataGrid.Columns>
    </DataGrid>
  </DockPanel>
</Window>
'@

# ----------------------------------------------------------------------------------
# Build the window
# ----------------------------------------------------------------------------------
$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

# Grab named controls.
$pathText        = $window.FindName('PathText')
$categoryPanel   = $window.FindName('CategoryPanel')
$screenshotCheck = $window.FindName('ScreenshotByMonthCheck')
$scanButton      = $window.FindName('ScanButton')
$organizeButton  = $window.FindName('OrganizeButton')
$undoButton      = $window.FindName('UndoButton')
$checkAllButton  = $window.FindName('CheckAllButton')
$uncheckAllButton= $window.FindName('UncheckAllButton')
$statusText      = $window.FindName('StatusText')
$grid            = $window.FindName('Grid')

$pathText.Text = "Desktop: $script:DesktopPath"

# Category on/off checkboxes (generated from the engine's category list).
$script:CategoryChecks = @{}
foreach ($cat in $script:Config.Categories) {
    $cb = New-Object System.Windows.Controls.CheckBox
    $cb.Content = $cat
    $cb.IsChecked = $true
    [void]$categoryPanel.Children.Add($cb)
    $script:CategoryChecks[$cat] = $cb
}

# DataTable backing the grid (gives reliable two-way checkbox binding).
$script:Table = New-Object System.Data.DataTable
[void]$script:Table.Columns.Add('Include',  [bool])
[void]$script:Table.Columns.Add('FileName', [string])
[void]$script:Table.Columns.Add('Location', [string])
[void]$script:Table.Columns.Add('Category', [string])
[void]$script:Table.Columns.Add('Source',   [string])   # hidden: full source path
[void]$script:Table.Columns.Add('Dest',     [string])   # hidden: resolved destination
$grid.ItemsSource = $script:Table.DefaultView

function Set-Status([string]$text) {
    $statusText.Text = $text
    # Let the UI repaint before any synchronous work continues.
    $window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
}

function Get-EnabledCategories {
    @($script:Config.Categories | Where-Object { $script:CategoryChecks[$_].IsChecked })
}

function Invoke-Scan {
    try {
        Set-Status 'Scanning the Desktop...'
        $enabled = Get-EnabledCategories
        $plan = New-OrganizePlan -DesktopPath $script:DesktopPath `
                                 -EnabledCategories $enabled `
                                 -ScreenshotByMonth:($screenshotCheck.IsChecked -eq $true) `
                                 -Config $script:Config

        $script:Table.Rows.Clear()
        foreach ($item in $plan) {
            $row = $script:Table.NewRow()
            $row['Include']  = $true
            $row['FileName'] = $item.FileName
            $row['Location'] = Split-Path -Parent $item.Source
            $row['Category'] = $item.Category
            $row['Source']   = $item.Source
            $row['Dest']     = $item.Destination
            $script:Table.Rows.Add($row)
        }

        $count = $script:Table.Rows.Count
        $organizeButton.IsEnabled = ($count -gt 0)
        if ($count -eq 0) {
            Set-Status 'Nothing to organize - no loose files match the current settings.'
        } else {
            Set-Status "Previewing $count file(s). Untick any you want to keep, then click Organize Now."
        }
    } catch {
        Set-Status "Scan failed: $($_.Exception.Message)"
    }
}

function Invoke-Organize {
    try {
        # Collect checked rows into engine plan items.
        $items = New-Object System.Collections.Generic.List[object]
        foreach ($row in $script:Table.Rows) {
            if ([bool]$row['Include']) {
                $items.Add([pscustomobject]@{
                    Category    = [string]$row['Category']
                    Source      = [string]$row['Source']
                    Destination = [string]$row['Dest']
                })
            }
        }

        if ($items.Count -eq 0) {
            Set-Status 'No files are checked - nothing to move.'
            return
        }

        $confirm = [System.Windows.MessageBox]::Show(
            "Move $($items.Count) file(s) into their category folders?`n`nNothing is overwritten, and the run is logged so you can undo it.",
            'Confirm organize', 'YesNo', 'Question')
        if ($confirm -ne 'Yes') { Set-Status 'Cancelled - nothing was moved.'; return }

        Set-Status "Moving $($items.Count) file(s)..."
        $result = Invoke-OrganizePlan -Plan $items.ToArray() `
                                      -DesktopPath $script:DesktopPath `
                                      -LogDirectory $script:LogDirectory

        Set-Status ("{0} files moved, {1} errors.  Log: {2}" -f `
                    $result.MovedCount, $result.FailedCount, $result.LogPath)

        if ($result.FailedCount -gt 0) {
            $msg = ($result.Failures | ForEach-Object { "- $($_.FileName): $($_.Error)" }) -join "`n"
            [void][System.Windows.MessageBox]::Show("Some files could not be moved (likely open/in use):`n`n$msg",
                'Some moves failed', 'OK', 'Warning')
        }

        # Refresh the preview to show whatever is still loose.
        Invoke-Scan
    } catch {
        Set-Status "Organize failed: $($_.Exception.Message)"
    }
}

function Invoke-Undo {
    try {
        $logFile = Get-LatestOrganizeLog -LogDirectory $script:LogDirectory
        if (-not $logFile) {
            Set-Status 'Nothing to undo - no previous run was found.'
            return
        }

        $preview = Get-OrganizeUndoPlan -LogFile $logFile
        $confirm = [System.Windows.MessageBox]::Show(
            ("Undo the last run?`n`nThis restores {0} file(s) to the Desktop. {1} ent(ies) will be skipped (already moved or the spot is taken)." -f `
                $preview.Restorable.Count, $preview.Skips.Count),
            'Confirm undo', 'YesNo', 'Question')
        if ($confirm -ne 'Yes') { Set-Status 'Cancelled - nothing was moved.'; return }

        Set-Status 'Restoring files...'
        $result = Invoke-OrganizeUndo -LogFile $logFile
        Set-Status ("Undo complete. {0} restored, {1} skipped." -f $result.Restored, $result.Skipped)
        Invoke-Scan
    } catch {
        Set-Status "Undo failed: $($_.Exception.Message)"
    }
}

function Set-AllChecked([bool]$value) {
    foreach ($row in $script:Table.Rows) { $row['Include'] = $value }
    $script:Table.AcceptChanges()
    $grid.Items.Refresh()
}

# Wire events.
$scanButton.Add_Click({ Invoke-Scan })
$organizeButton.Add_Click({ Invoke-Organize })
$undoButton.Add_Click({ Invoke-Undo })
$checkAllButton.Add_Click({ Set-AllChecked $true })
$uncheckAllButton.Add_Click({ Set-AllChecked $false })

# Auto-scan on open so the user immediately sees the preview.
$window.Add_Loaded({ Invoke-Scan })

[void]$window.ShowDialog()
