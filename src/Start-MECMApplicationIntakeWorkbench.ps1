#requires -Version 5.1
#requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Xaml
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-FileSystemProviderPath {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -like 'FileSystem::*') { return $Path }
    return "FileSystem::$Path"
}

function Normalize-MetadataText {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return (([string]$Value -replace '\s+',' ').Trim())
}

function ConvertTo-SafeSourcePathComponent {
    param(
        [AllowNull()][object]$Value,
        [Parameter(Mandatory)][string]$Fallback
    )
    $component = Normalize-MetadataText -Value $Value
    if ([string]::IsNullOrWhiteSpace($component)) { $component = $Fallback }
    $component = $component -replace '[<>:"/\\|?*]', '_'
    $component = ($component -replace '\s+',' ').Trim().TrimEnd([char[]]@('.',' '))
    if ([string]::IsNullOrWhiteSpace($component)) { $component = $Fallback }
    return $component
}

function Test-FileSystemPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('Any','Leaf','Container')][string]$PathType = 'Any'
    )
    $providerPath = Get-FileSystemProviderPath -Path $Path
    switch ($PathType) {
        'Leaf'      { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $providerPath -PathType Leaf }
        'Container' { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $providerPath -PathType Container }
        default     { return Microsoft.PowerShell.Management\Test-Path -LiteralPath $providerPath }
    }
}

function New-FileSystemDirectory {
    param([Parameter(Mandatory)][string]$Path)
    Microsoft.PowerShell.Management\New-Item -Path (Get-FileSystemProviderPath -Path $Path) -ItemType Directory -Force
}


function Get-SafePropertyValue {
    param(
        [Parameter(Mandatory)] [object] $InputObject,
        [Parameter(Mandatory)] [string[]] $PropertyName
    )

    foreach ($name in $PropertyName) {
        $property = $InputObject.PSObject.Properties[$name]
        if ($null -ne $property -and $null -ne $property.Value) {
            return $property.Value
        }
    }
    return $null
}

function Get-FileSystemParentPath {
    param([Parameter(Mandatory)][string]$Path)
    $trimmed = $Path.TrimEnd('\\')
    if ($trimmed -match '^\\\\[^\\]+\\[^\\]+$') { return $null }
    $lastSlash = $trimmed.LastIndexOf('\\')
    if ($lastSlash -lt 1) { return $null }
    return $trimmed.Substring(0,$lastSlash)
}

$script:AppVersion = '0.25.4'
$script:State = [ordered]@{
    Connected       = $false
    ModuleImported  = $false
    SiteDriveReady  = $false
    SiteConnected   = $false
    FolderRefresh   = 'NotRun'
    DpRefresh       = 'NotRun'
    CollectionRefresh = 'NotRun'
    InstallerPath   = $null
    MsiMetadata     = $null
    InstallerMetadata = $null
    InstallerType   = $null
    Application     = $null
    SiteCode        = 'ABC'
    ProviderServer  = 'CM01.contoso.com'
    SourceRoot      = '\\CM01\MECMSources$\Applications'
    LocalSourceBackingRoot = 'C:\MECMSources'
    LogRoot         = Join-Path $PSScriptRoot 'Logs'
    ManifestRoot    = Join-Path $PSScriptRoot 'Manifests'
    IconCacheRoot   = Join-Path $PSScriptRoot 'IconCache'
    BatchItems      = New-Object System.Collections.ArrayList
    DeviceCollections = @()
    LastValidatedPath = $null
    LastValidationPassed = $false
    PreviewBusy = $false
    LastCreatedApplicationName = $null
    Processing = $false
    CancelAfterCurrent = $false
    LastBatchSummary = $null
    CurrentBatchIndex = 0
    CurrentBatchTotal = 0
    CurrentQueueItem = $null
    SelectionSyncBusy = $false
    ConnectionState = 'Disconnected'
}

foreach ($path in @($script:State.LogRoot, $script:State.ManifestRoot, $script:State.IconCacheRoot)) {
    if (-not (Test-FileSystemPath -Path $path)) {
        New-FileSystemDirectory -Path $path | Out-Null
    }
}

$script:LogFile = Join-Path $script:State.LogRoot ("MECM-AppIntake-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))


function Get-ImageDimensions {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $image = [System.Drawing.Image]::FromFile($Path)
        try { return [pscustomobject]@{ Width=$image.Width; Height=$image.Height } }
        finally { $image.Dispose() }
    }
    catch { return [pscustomobject]@{ Width=0; Height=0 } }
}

function Export-AssociatedInstallerIcon {
    param(
        [Parameter(Mandatory)][string]$InstallerPath,
        [Parameter(Mandatory)][string]$DestinationPath
    )
    $icon = [System.Drawing.Icon]::ExtractAssociatedIcon($InstallerPath)
    if ($null -eq $icon) { return $false }
    try {
        $bitmap = $icon.ToBitmap()
        try {
            $bitmap.Save($DestinationPath,[System.Drawing.Imaging.ImageFormat]::Png)
        }
        finally { $bitmap.Dispose() }
    }
    finally { $icon.Dispose() }
    return (Test-FileSystemPath -Path $DestinationPath -PathType Leaf)
}

function Get-InstallerIconRecommendation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$InstallerType,
        [string]$Sha256 = ''
    )
    $safeBase = ([IO.Path]::GetFileNameWithoutExtension($Path) -replace '[^A-Za-z0-9_.-]','_')
    $suffix = if ($Sha256.Length -ge 12) { $Sha256.Substring(0,12) } else { [Guid]::NewGuid().ToString('N').Substring(0,12) }
    $destination = Join-Path $script:State.IconCacheRoot ("$safeBase-$suffix.png")
    try {
        if (-not (Test-FileSystemPath -Path $destination -PathType Leaf)) {
            if (-not (Export-AssociatedInstallerIcon -InstallerPath $Path -DestinationPath $destination)) { throw 'No associated icon was returned.' }
        }
        $dimensions = Get-ImageDimensions -Path $destination
        $quality = if ($dimensions.Width -lt 64 -or $dimensions.Height -lt 64) { 'Low resolution' } else { 'Candidate' }
        $source = if ($InstallerType -eq 'EXE') { 'Extracted from installer executable' } else { 'Extracted shell icon from MSI; may be generic' }
        return [pscustomobject]@{
            IconMode='Extracted'; IconPath=$destination; ExtractedIconPath=$destination; IconSource=$source;
            IconQuality=$quality; IconWidth=$dimensions.Width; IconHeight=$dimensions.Height
        }
    }
    catch {
        return [pscustomobject]@{
            IconMode='None'; IconPath=''; ExtractedIconPath=''; IconSource='Unavailable';
            IconQuality=$_.Exception.Message; IconWidth=0; IconHeight=0
        }
    }
}

function Get-WpfImageSource {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-FileSystemPath -Path $Path -PathType Leaf)) { return $null }
    $image = New-Object System.Windows.Media.Imaging.BitmapImage
    $image.BeginInit()
    $image.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
    $image.UriSource = New-Object System.Uri($Path,[System.UriKind]::Absolute)
    $image.EndInit()
    $image.Freeze()
    return $image
}

function Update-IconPreview {
    param([object]$Item = $script:State.CurrentQueueItem)
    if (-not $script:Controls -or -not $script:Controls.IconPreview) { return }
    if ($null -eq $Item) {
        $script:Controls.IconPreview.Source = $null
        $script:Controls.IconStatusText.Text = 'No application selected.'
        return
    }
    $path = [string](Get-QueueItemValue -Item $Item -Name 'IconPath' -Default '')
    $mode = [string](Get-QueueItemValue -Item $Item -Name 'IconMode' -Default 'None')
    $source = [string](Get-QueueItemValue -Item $Item -Name 'IconSource' -Default 'Unavailable')
    $quality = [string](Get-QueueItemValue -Item $Item -Name 'IconQuality' -Default '')
    try { $script:Controls.IconPreview.Source = Get-WpfImageSource -Path $path }
    catch { $script:Controls.IconPreview.Source = $null; $quality = "Preview failed: $($_.Exception.Message)" }
    if ($mode -eq 'None' -or [string]::IsNullOrWhiteSpace($path)) {
        $script:Controls.IconStatusText.Text = 'No icon selected. Application creation will continue without an icon.'
    } else {
        $width = Get-QueueItemValue -Item $Item -Name 'IconWidth' -Default 0
        $height = Get-QueueItemValue -Item $Item -Name 'IconHeight' -Default 0
        $sizeText = if ([int]$width -gt 0 -and [int]$height -gt 0) { " | ${width}x${height}" } else { '' }
        $script:Controls.IconStatusText.Text = "Icon source: $source | Quality: $quality$sizeText"
    }
    $extracted = [string](Get-QueueItemValue -Item $Item -Name 'ExtractedIconPath' -Default '')
    $script:Controls.UseExtractedIconButton.IsEnabled = (-not [string]::IsNullOrWhiteSpace($extracted) -and (Test-FileSystemPath -Path $extracted -PathType Leaf))
}

function Invoke-UiRefresh {
    if (-not [System.Windows.Application]::Current) { return }
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    [System.Windows.Threading.Dispatcher]::CurrentDispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::Background,
        [System.Windows.Threading.DispatcherOperationCallback]{ param($f) $f.Continue = $false; return $null },
        $frame
    ) | Out-Null
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}

function Set-ConnectionState {
    param(
        [ValidateSet('Disconnected','Connecting','Connected','Failed')][string]$State,
        [string]$Detail = ''
    )
    if (-not $script:Controls) { return }
    $script:State.ConnectionState = $State
    $text = switch ($State) {
        'Connecting' { 'Connecting to MECM' }
        'Connected' { if ($Detail) { "Connected - $Detail" } else { 'Connected' } }
        'Failed' { if ($Detail) { "Connection Failed - $Detail" } else { 'Connection Failed' } }
        default { 'Not Connected' }
    }
    $icon = switch ($State) {
        'Connecting' { [string][char]0x25CC }
        'Connected' { [string][char]0x25CF }
        'Failed' { [string][char]0x2716 }
        default { [string][char]0x25B2 }
    }
    $colors = switch ($State) {
        'Connecting' { @{ Background='#2463A8'; Foreground='White' } }
        'Connected' { @{ Background='#2F7D4A'; Foreground='White' } }
        'Failed' { @{ Background='#B42318'; Foreground='White' } }
        default { @{ Background='#B36B00'; Foreground='White' } }
    }
    $script:Controls.ConnectionIcon.Text = $icon
    $script:Controls.ConnectionStatus.Text = $text
    $script:Controls.ConnectionStatusBorder.Background = $colors.Background
    $script:Controls.ConnectionStatus.Foreground = $colors.Foreground
    $script:Controls.ConnectionIcon.Foreground = $colors.Foreground
    $script:Controls.ConnectionActivity.Visibility = if ($State -eq 'Connecting') { 'Visible' } else { 'Collapsed' }
    $script:Controls.ConnectionInstruction.Text = switch ($State) {
        'Connecting' { 'Establishing the site connection and loading MECM targets...' }
        'Connected' { 'MECM is ready. Intake, validation, and commit actions are now available.' }
        'Failed' { 'Connection failed. Verify the site code and provider, then try again.' }
        default { 'First step: enter the site and provider, then connect before adding or processing applications.' }
    }
    Update-ActionAvailability
    Invoke-UiRefresh
}

function Update-ActionAvailability {
    if (-not $script:Controls) { return }
    $connected = [bool]$script:State.Connected
    $processing = [bool]$script:State.Processing
    $connecting = $script:State.ConnectionState -eq 'Connecting'
    $hasQueue = $script:State.BatchItems.Count -gt 0
    $hasSelection = $null -ne $script:State.CurrentQueueItem

    # The entire workbench workflow remains unavailable until a valid MECM
    # connection exists. This makes connection the unmistakable first action
    # and prevents queue configuration from being created against stale targets.
    $script:Controls.Tabs.IsEnabled = ($connected -and -not $processing)
    $script:Controls.SiteCodeText.IsEnabled = (-not $processing -and -not $connecting)
    $script:Controls.ProviderText.IsEnabled = (-not $processing -and -not $connecting)
    $script:Controls.ConnectButton.IsEnabled = (-not $processing -and -not $connecting)
    $script:Controls.ConnectButton.Content = if ($connected) { 'Reconnect to MECM' } elseif ($connecting) { 'Connecting...' } else { '1. Connect to MECM' }

    $script:Controls.ProcessBatchButton.IsEnabled = ($connected -and $hasQueue -and -not $processing)
    $script:Controls.ValidateButton.IsEnabled = ($connected -and $hasSelection -and -not $processing)
    $script:Controls.ValidateAllButton.IsEnabled = ($connected -and $hasQueue -and -not $processing)
    $script:Controls.CreateButton.IsEnabled = ($connected -and -not $processing -and $script:State.LastValidationPassed -and $script:State.LastValidatedPath -eq $script:State.InstallerPath)
    $script:Controls.CreateAppFolderButton.IsEnabled = ($connected -and -not $processing)
    $script:Controls.DistributionModeCombo.IsEnabled = ($connected -and -not $processing)
    $script:Controls.DistributionTargetCombo.IsEnabled = ($connected -and -not $processing)
}

function Update-LiveQueueStatus {
    if (-not $script:Controls -or -not $script:Controls.QueueStatusText) { return }
    $items = @($script:State.BatchItems)
    $counts = [ordered]@{
        Queued = @($items | Where-Object { $_.Status -in @('Ready','Validated') }).Count
        Processing = @($items | Where-Object { $_.Status -eq 'Processing' }).Count
        Success = @($items | Where-Object { $_.Status -eq 'Success' }).Count
        Failed = @($items | Where-Object { $_.Status -eq 'Failed' }).Count
        Blocked = @($items | Where-Object { $_.Status -eq 'Blocked' }).Count
        Cancelled = @($items | Where-Object { $_.Status -eq 'Cancelled' }).Count
    }
    $script:Controls.QueueStatusText.Text = "Queue status: Ready $($counts.Queued)  |  Processing $($counts.Processing)  |  Success $($counts.Success)  |  Failed $($counts.Failed)  |  Blocked $($counts.Blocked)  |  Cancelled $($counts.Cancelled)"
}

function Update-ProcessingStatus {
    param(
        [string]$Stage,
        [int]$StagePercent = -1,
        [object]$Item = $null
    )
    if (-not $script:Controls) { return }
    $name = if ($Item) { [string]$Item.Application } elseif ($script:State.Application) { [string]$script:State.Application } else { '' }
    $position = if ($script:State.CurrentBatchTotal -gt 0) { "$($script:State.CurrentBatchIndex) of $($script:State.CurrentBatchTotal)" } else { 'Selected application' }
    $script:Controls.ProgressTitleText.Text = if ($name) { "Processing $position - $name" } else { "Processing $position" }
    $script:Controls.ProgressStageText.Text = $Stage
    # Current MECM operations have no trustworthy percentage callback. Keep this
    # bar indeterminate so it communicates activity without implying precision.
    $script:Controls.StageProgressBar.IsIndeterminate = $true
    if ($script:State.CurrentBatchTotal -gt 0) {
        $script:Controls.OverallProgressBar.IsIndeterminate = $false
        $script:Controls.OverallProgressBar.Maximum = $script:State.CurrentBatchTotal
        $script:Controls.OverallProgressBar.Value = [Math]::Max(0,$script:State.CurrentBatchIndex - 1)
        $script:Controls.OverallProgressText.Text = "$([Math]::Max(0,$script:State.CurrentBatchIndex - 1)) of $($script:State.CurrentBatchTotal) complete"
    } else {
        $script:Controls.OverallProgressBar.IsIndeterminate = $true
        $script:Controls.OverallProgressText.Text = 'Single application operation'
    }
    Update-LiveQueueStatus
    Invoke-UiRefresh
}

function Set-ProcessingUi {
    param([bool]$IsProcessing)
    $script:State.Processing = $IsProcessing
    $script:Controls.ProgressPanel.Visibility = if ($IsProcessing) { 'Visible' } else { 'Collapsed' }
    $script:Controls.CancelBatchButton.Visibility = if ($IsProcessing -and $script:State.CurrentBatchTotal -gt 0) { 'Visible' } else { 'Collapsed' }
    if ($IsProcessing -and -not $script:State.CancelAfterCurrent) { $script:Controls.CancelBatchButton.Content = 'Cancel after current application' }
    foreach ($name in @('AddBatchButton','RemoveBatchButton','ClearBatchButton','ConnectButton','BrowseButton','BatchGrid','ReviewQueueGrid','DeploymentTypeQueueGrid','PreviousAppButton','NextAppButton','InstallCommandText','UninstallCommandText','ResetCommandsButton','InstallerProfileText','CommandApprovalPanel','CommandApprovalHeading','CommandApprovalCheck','ExeValidationRequirementText','DetectionTypeCombo','DetectionPathText','DetectionFileNameText','RegistryHiveCombo','RegistryKeyText','RegistryValueNameText','DetectionScriptText','AdminNameText','LocalizedNameText','ChooseIconButton','UseExtractedIconButton','NoIconButton','PublisherText','VersionText','DescriptionText','CommentsText','IconPreview','IconStatusText','SourceRootText','BrowseSourceButton','CreateSourceButton','AutoCreateSourceCheck','FolderCombo')) {
        if ($script:Controls[$name]) { $script:Controls[$name].IsEnabled = -not $IsProcessing }
    }
    $script:Controls.CancelBatchButton.IsEnabled = $IsProcessing -and -not $script:State.CancelAfterCurrent
    Update-ActionAvailability
    Update-LiveQueueStatus
    Invoke-UiRefresh
}

function Write-WorkbenchLog {
    param(
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('INFO','WARN','ERROR','PASS')] [string] $Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath (Get-FileSystemProviderPath -Path $script:LogFile) -Value $line -Encoding UTF8
    if ($script:Controls -and $script:Controls.LogBox) {
        $script:Controls.LogBox.AppendText($line + [Environment]::NewLine)
        $script:Controls.LogBox.ScrollToEnd()
    }
}

function Show-ErrorDialog {
    param([string]$Title, [string]$Message)
    [System.Windows.MessageBox]::Show($Message, $Title, 'OK', 'Error') | Out-Null
}

function Get-MsiProperty {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Property
    )

    $installer = New-Object -ComObject WindowsInstaller.Installer
    try {
        $database = $installer.GetType().InvokeMember('OpenDatabase','InvokeMethod',$null,$installer,@($Path,0))
        $query = "SELECT `Value` FROM `Property` WHERE `Property`='$Property'"
        $view = $database.GetType().InvokeMember('OpenView','InvokeMethod',$null,$database,@($query))
        $view.GetType().InvokeMember('Execute','InvokeMethod',$null,$view,$null) | Out-Null
        $record = $view.GetType().InvokeMember('Fetch','InvokeMethod',$null,$view,$null)
        if ($record) {
            return $record.GetType().InvokeMember('StringData','GetProperty',$null,$record,1)
        }
        return $null
    }
    finally {
        foreach ($object in @($record,$view,$database,$installer)) {
            if ($null -ne $object) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($object) }
        }
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
    }
}

function Get-MsiMetadata {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-FileSystemPath -Path $Path -PathType Leaf)) {
        throw "MSI file not found: $Path"
    }
    if ([IO.Path]::GetExtension($Path) -ne '.msi') {
        throw 'Version 0.1 supports MSI files only.'
    }

    $signature = Get-AuthenticodeSignature -LiteralPath (Get-FileSystemProviderPath -Path $Path)
    $hash = Get-FileHash -LiteralPath (Get-FileSystemProviderPath -Path $Path) -Algorithm SHA256

    [pscustomobject]@{
        ProductName    = Get-MsiProperty -Path $Path -Property 'ProductName'
        ProductVersion = Get-MsiProperty -Path $Path -Property 'ProductVersion'
        Manufacturer   = Get-MsiProperty -Path $Path -Property 'Manufacturer'
        ProductCode    = Get-MsiProperty -Path $Path -Property 'ProductCode'
        UpgradeCode    = Get-MsiProperty -Path $Path -Property 'UpgradeCode'
        Template       = Get-MsiProperty -Path $Path -Property 'Template'
        FileName       = [IO.Path]::GetFileName($Path)
        FullPath       = $Path
        Sha256         = $hash.Hash
        Signature      = $signature.Status.ToString()
        Signer         = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
    }
}


function ConvertTo-CleanExeApplicationName {
    param([Parameter(Mandatory)][string]$Path)

    $name = [IO.Path]::GetFileNameWithoutExtension($Path)
    $name = $name -replace '(?i)\b(setup|installer|install|bootstrapper|offline|online|standalone)\b',' '
    $name = $name -replace '(?i)(^|[-_. ])(x64|x86|amd64|arm64|win32|win64|allusers|user|machine|all[-_. ]?os|enu)(?=$|[-_. ])',' '
    $name = $name -replace '(?i)(^|[-_. ])v?\d+(?:[._-]\d+){1,4}(?=$|[-_. ])',' '
    $name = $name -replace '[-_.]+',' '
    $name = $name -creplace '([a-z0-9])([A-Z])','$1 $2'
    $name = $name -replace '(?i)\b(setup|installer|install|bootstrapper|offline|online|standalone)\b',' '
    $name = $name -replace '\s+',' '
    $name = $name.Trim()

    $name = $name -replace '(?i)^Git Hub Desktop$', 'GitHub Desktop'
    $name = $name -replace '(?i)^Git Hub$', 'GitHub'
    $name = $name -replace '(?i)^VSCode$', 'Visual Studio Code'
    $name = $name -replace '(?i)^VS Code$', 'Visual Studio Code'
    $name = $name -replace '(?i)^V S Code$', 'Visual Studio Code'

    if ([string]::IsNullOrWhiteSpace($name)) {
        return [IO.Path]::GetFileNameWithoutExtension($Path)
    }
    return $name
}

function Test-CredibleExeProductName {
    param([AllowNull()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return $false }
    $candidate = ($Name -replace '\s+',' ').Trim()
    if ($candidate.Length -gt 80) { return $false }
    if ($candidate -match '(?i)^(application|program|product|setup|installer|install|bootstrapper|update|updater)$') { return $false }
    if ($candidate -match '(?i)\b(simple collaboration from your desktop|welcome to|designed to|the easiest way|for your desktop|from your desktop|helps you|lets you)\b') { return $false }
    if ($candidate -match '[.!?]$' -and ($candidate -split '\s+').Count -ge 4) { return $false }

    $words = @($candidate -split '\s+')
    if ($words.Count -ge 6) {
        $commonLowercase = @($words | Where-Object { $_ -cmatch '^(a|an|and|as|at|by|for|from|in|of|on|or|the|to|with|your)$' }).Count
        if ($commonLowercase -ge 2) { return $false }
    }
    return $true
}

function Get-ExeApplicationNameRecommendation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [AllowNull()][string]$ProductName,
        [AllowNull()][string]$FileDescription
    )

    $cleanFileName = ConvertTo-CleanExeApplicationName -Path $Path
    $normalizedProductName = if ($ProductName) { ($ProductName -replace '\s+',' ').Trim() } else { '' }
    $normalizedDescription = if ($FileDescription) { ($FileDescription -replace '\s+',' ').Trim() } else { '' }

    if (Test-CredibleExeProductName -Name $normalizedProductName) {
        return [pscustomobject]@{
            Name = $normalizedProductName
            Source = 'ProductName metadata'
            RejectedProductName = ''
            RejectionReason = ''
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($cleanFileName)) {
        return [pscustomobject]@{
            Name = $cleanFileName
            Source = 'normalized file name'
            RejectedProductName = $normalizedProductName
            RejectionReason = $(if ($normalizedProductName) { 'ProductName metadata did not resemble a reliable product title.' } else { 'ProductName metadata was blank.' })
        }
    }

    if (Test-CredibleExeProductName -Name $normalizedDescription) {
        return [pscustomobject]@{
            Name = $normalizedDescription
            Source = 'FileDescription metadata'
            RejectedProductName = $normalizedProductName
            RejectionReason = 'ProductName metadata was not usable and the file name could not be normalized.'
        }
    }

    return [pscustomobject]@{
        Name = [IO.Path]::GetFileNameWithoutExtension($Path)
        Source = 'raw file name'
        RejectedProductName = $normalizedProductName
        RejectionReason = 'No reliable embedded application name was available.'
    }
}

function Get-ExeInstallerProfile {
    param([Parameter(Mandatory)][string]$Path)

    $stream = [IO.File]::OpenRead($Path)
    try {
        $length = [Math]::Min([int64]8388608, $stream.Length)
        $buffer = New-Object byte[] ([int]$length)
        [void]$stream.Read($buffer,0,$buffer.Length)
    }
    finally { $stream.Dispose() }

    $ascii = [Text.Encoding]::ASCII.GetString($buffer)
    $unicode = [Text.Encoding]::Unicode.GetString($buffer)
    $combined = $ascii + "`n" + $unicode

    $framework = 'Unknown or custom EXE'
    $confidence = 'Unknown'
    $fileName = [IO.Path]::GetFileName($Path)
    $install = "`"$fileName`""
    $guidance = 'No recognized installer framework. The executable file name has been populated as the install command. Append verified switches, configure detection, and approve the command before creation.'

    if ($combined -match 'Inno Setup|INNOSETUP') {
        $framework = 'Inno Setup'; $confidence = 'Likely'
        $install = "`"$fileName`" /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP-"
        $guidance = 'Inno Setup signature found. Suggested install switches require technician review; uninstall command must be supplied.'
    }
    elseif ($combined -match 'Nullsoft|NSIS|Nullsoft Install System') {
        $framework = 'NSIS'; $confidence = 'Likely'
        $install = "`"$fileName`" /S"
        $guidance = 'NSIS signature found. /S is case-sensitive for many packages. Verify behavior and supply the uninstall command.'
    }
    elseif ($combined -match 'BurnEngine|WixBundle|WiX Toolset|WixStdBA') {
        $framework = 'WiX Burn'; $confidence = 'Likely'
        $install = "`"$fileName`" /quiet /norestart"
        $guidance = 'WiX Burn signature found. Suggested switches require technician review; uninstall command must be supplied.'
    }
    elseif ($combined -match 'InstallShield|InstallScript') {
        $framework = 'InstallShield'; $confidence = 'Suggested'
        $install = "`"$fileName`" /s"
        $guidance = 'InstallShield signature found. Silent behavior varies and may require a response file. Verify both commands manually.'
    }
    elseif ($combined -match 'Advanced Installer') {
        $framework = 'Advanced Installer'; $confidence = 'Suggested'
        $install = "`"$fileName`" /exenoui /qn"
        $guidance = 'Advanced Installer signature found. Suggested switches require technician verification; uninstall command must be supplied.'
    }
    elseif ($combined -match 'SquirrelAwareVersion|Update\.exe --install|Squirrel') {
        $framework = 'Squirrel'; $confidence = 'Suggested'
        $install = "`"$fileName`" --silent"
        $guidance = 'Squirrel-related signature found. Packaging behavior varies; verify install context, detection, and uninstall manually.'
    }

    [pscustomobject]@{
        Framework = $framework
        Confidence = $confidence
        SuggestedInstall = $install
        SuggestedUninstall = ''
        Guidance = $guidance
    }
}

function Get-ExeMetadata {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-FileSystemPath -Path $Path -PathType Leaf)) { throw "EXE file not found: $Path" }
    if ([IO.Path]::GetExtension($Path).ToLowerInvariant() -ne '.exe') { throw 'The selected file is not an EXE.' }

    $signature = Get-AuthenticodeSignature -LiteralPath (Get-FileSystemProviderPath -Path $Path)
    $hash = Get-FileHash -LiteralPath (Get-FileSystemProviderPath -Path $Path) -Algorithm SHA256
    $versionInfo = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    $profile = Get-ExeInstallerProfile -Path $Path
    $nameRecommendation = Get-ExeApplicationNameRecommendation -Path $Path -ProductName $versionInfo.ProductName -FileDescription $versionInfo.FileDescription
    $productName = $nameRecommendation.Name
    $productVersion = Normalize-MetadataText -Value (@($versionInfo.ProductVersion,$versionInfo.FileVersion,'1.0.0') | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -First 1)

    [pscustomobject]@{
        InstallerType   = 'EXE'
        ProductName     = Normalize-MetadataText -Value $productName
        ProductVersion  = [string]$productVersion
        Manufacturer    = Normalize-MetadataText -Value $versionInfo.CompanyName
        NameSource      = [string]$nameRecommendation.Source
        EmbeddedProductName = [string](($versionInfo.ProductName -replace '\s+',' ').Trim())
        RejectedProductName = [string]$nameRecommendation.RejectedProductName
        NameRejectionReason = [string]$nameRecommendation.RejectionReason
        ProductCode     = ''
        UpgradeCode     = ''
        Template        = ''
        FileName        = [IO.Path]::GetFileName($Path)
        FullPath        = $Path
        Sha256          = $hash.Hash
        Signature       = $signature.Status.ToString()
        Signer          = if ($signature.SignerCertificate) { $signature.SignerCertificate.Subject } else { '' }
        Framework       = $profile.Framework
        CommandConfidence = $profile.Confidence
        SuggestedInstall = $profile.SuggestedInstall
        SuggestedUninstall = $profile.SuggestedUninstall
        CommandGuidance = $profile.Guidance
    }
}

function Get-InstallerMetadata {
    param([Parameter(Mandatory)][string]$Path)
    switch ([IO.Path]::GetExtension($Path).ToLowerInvariant()) {
        '.msi' {
            $m = Get-MsiMetadata -Path $Path
            $m | Add-Member -NotePropertyName InstallerType -NotePropertyValue 'MSI' -Force
            $m | Add-Member -NotePropertyName Framework -NotePropertyValue 'Windows Installer' -Force
            $m | Add-Member -NotePropertyName CommandConfidence -NotePropertyValue 'Verified' -Force
            $m | Add-Member -NotePropertyName CommandGuidance -NotePropertyValue 'Commands are derived from Windows Installer metadata and remain technician-editable.' -Force
            $m | Add-Member -NotePropertyName NameSource -NotePropertyValue 'Windows Installer ProductName' -Force
            $m | Add-Member -NotePropertyName EmbeddedProductName -NotePropertyValue $m.ProductName -Force
            $m | Add-Member -NotePropertyName RejectedProductName -NotePropertyValue '' -Force
            $m | Add-Member -NotePropertyName NameRejectionReason -NotePropertyValue '' -Force
            return $m
        }
        '.exe' { return Get-ExeMetadata -Path $Path }
        default { throw 'Supported installer types are MSI and EXE.' }
    }
}

function Get-DefaultMsiCommands {
    param([Parameter(Mandatory)] [object] $Metadata)
    [pscustomobject]@{
        Install   = "msiexec.exe /i `"$($Metadata.FileName)`" /qn /norestart"
        Uninstall = "msiexec.exe /x $($Metadata.ProductCode) /qn /norestart"
    }
}


function Get-DefaultInstallerCommands {
    param([Parameter(Mandatory)][object]$Metadata)
    if ([string]$Metadata.InstallerType -eq 'MSI') { return Get-DefaultMsiCommands -Metadata $Metadata }
    [pscustomobject]@{
        Install = [string]$Metadata.SuggestedInstall
        Uninstall = [string]$Metadata.SuggestedUninstall
    }
}

function Save-SelectedDeploymentTypeSettings {
    if ($script:State.PreviewBusy -or -not $script:Controls -or -not $script:Controls.BatchGrid) { return }
    $item = $script:State.CurrentQueueItem
    if (-not $item) { return }
    $item.InstallCommand = $script:Controls.InstallCommandText.Text
    $item.UninstallCommand = $script:Controls.UninstallCommandText.Text
    $item.DetectionType = Get-ComboValue -Combo $script:Controls.DetectionTypeCombo
    $item.DetectionPath = $script:Controls.DetectionPathText.Text
    $item.DetectionFileName = $script:Controls.DetectionFileNameText.Text
    $item.RegistryHive = Get-ComboValue -Combo $script:Controls.RegistryHiveCombo
    $item.RegistryKey = $script:Controls.RegistryKeyText.Text
    $item.RegistryValueName = $script:Controls.RegistryValueNameText.Text
    $item.DetectionScript = $script:Controls.DetectionScriptText.Text
    $item.ExeCommandsConfirmed = [bool]$script:Controls.CommandApprovalCheck.IsChecked
}

function Update-DetectionEditorVisibility {
    $type = Get-ComboValue -Combo $script:Controls.DetectionTypeCombo
    $script:Controls.FileDetectionPanel.Visibility = if ($type -eq 'File exists') { 'Visible' } else { 'Collapsed' }
    $script:Controls.RegistryDetectionPanel.Visibility = if ($type -eq 'Registry key/value exists') { 'Visible' } else { 'Collapsed' }
    $script:Controls.ScriptDetectionPanel.Visibility = if ($type -eq 'PowerShell script') { 'Visible' } else { 'Collapsed' }
    $script:Controls.MsiDetectionPanel.Visibility = if ($type -eq 'MSI product code') { 'Visible' } else { 'Collapsed' }
}

function Load-DeploymentTypeSettings {
    param([Parameter(Mandatory)] [object] $Item)
    Initialize-QueueItemExeProperties -Item $Item
    $script:State.PreviewBusy = $true
    try {
        $script:Controls.InstallCommandText.Text = [string]$Item.InstallCommand
        $script:Controls.UninstallCommandText.Text = [string]$Item.UninstallCommand
        $script:Controls.DetectionTypeCombo.Text = [string]$Item.DetectionType
        $script:Controls.DetectionPathText.Text = [string]$Item.DetectionPath
        $script:Controls.DetectionFileNameText.Text = [string]$Item.DetectionFileName
        $script:Controls.RegistryHiveCombo.Text = [string]$Item.RegistryHive
        $script:Controls.RegistryKeyText.Text = [string]$Item.RegistryKey
        $script:Controls.RegistryValueNameText.Text = [string]$Item.RegistryValueName
        $script:Controls.DetectionScriptText.Text = [string]$Item.DetectionScript
        $script:Controls.InstallerProfileText.Text = if ([string]$Item.InstallerType -eq 'EXE') { "EXE profile: $($Item.InstallerFramework) | command confidence: $($Item.CommandConfidence). $($Item.CommandGuidance)" } else { 'MSI profile: Windows Installer metadata; default commands are verified and technician-editable.' }
        $script:Controls.CommandApprovalPanel.Visibility = if ([string]$Item.InstallerType -eq 'EXE') { 'Visible' } else { 'Collapsed' }
        $script:Controls.ExeValidationRequirementText.Visibility = if ([string]$Item.InstallerType -eq 'EXE') { 'Visible' } else { 'Collapsed' }
        $script:Controls.CommandApprovalCheck.IsChecked = [bool]$Item.ExeCommandsConfirmed
        Update-CommandApprovalPanelVisual
        Update-DetectionEditorVisibility
    } finally { $script:State.PreviewBusy = $false }
}

function Import-ConfigurationManagerModule {
    $script:State.ModuleImported = $false

    # SMS_ADMIN_UI_PATH normally points to the console's bin\i386 directory.
    # ConfigurationManager.psd1 is one level above that directory.  v0.3
    # incorrectly stripped the final path component first and then looked in
    # the wrong folder.
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:SMS_ADMIN_UI_PATH) {
        $candidates.Add((Join-Path $env:SMS_ADMIN_UI_PATH '..\ConfigurationManager.psd1'))
        $candidates.Add((Join-Path (Split-Path $env:SMS_ADMIN_UI_PATH -Parent) 'ConfigurationManager.psd1'))
    }

    $availableModule = Get-Module -ListAvailable -Name ConfigurationManager | Select-Object -First 1
    if ($availableModule -and $availableModule.Path) {
        $candidates.Add([string]$availableModule.Path)
    }

    $modulePath = $null
    foreach ($candidate in $candidates | Select-Object -Unique) {
        try {
            $resolved = Resolve-Path -LiteralPath $candidate -ErrorAction Stop
            if ($resolved) {
                $modulePath = $resolved.ProviderPath
                break
            }
        }
        catch {
            Write-WorkbenchLog "ConfigurationManager module candidate not found: $candidate" 'INFO'
        }
    }

    if (-not $modulePath) {
        $candidateText = if ($candidates.Count) { $candidates -join '; ' } else { 'No candidate paths were available.' }
        throw "ConfigurationManager.psd1 was not found. Checked: $candidateText"
    }

    Import-Module -Name $modulePath -Force -ErrorAction Stop
    if (-not (Get-Module -Name ConfigurationManager)) {
        throw "ConfigurationManager module import returned without loading the module from $modulePath"
    }

    $script:State.ModuleImported = $true
    Write-WorkbenchLog "Imported ConfigurationManager module from $modulePath" 'PASS'
}

function Connect-MecmSite {
    param([string]$SiteCode,[string]$ProviderServer)

    $script:State.Connected = $false
    $script:State.SiteConnected = $false
    $script:State.SiteDriveReady = $false
    $script:State.FolderRefresh = 'NotRun'
    $script:State.DpRefresh = 'NotRun'
    $script:State.CollectionRefresh = 'NotRun'

    Import-ConfigurationManagerModule
    $drive = Get-PSDrive -Name $SiteCode -PSProvider CMSite -ErrorAction SilentlyContinue
    if (-not $drive) {
        New-PSDrive -Name $SiteCode -PSProvider CMSite -Root $ProviderServer | Out-Null
        Write-WorkbenchLog "Created CMSite drive $SiteCode`: for $ProviderServer" 'PASS'
    }
    $script:State.SiteDriveReady = $true
    Set-Location "$SiteCode`:"
    $site = Get-CMSite -SiteCode $SiteCode
    if (-not $site) { throw "Site $SiteCode was not returned by the provider." }
    $script:State.Connected = $true
    $script:State.SiteConnected = $true
    $script:State.SiteCode = $SiteCode
    $script:State.ProviderServer = $ProviderServer
    Write-WorkbenchLog "Connected to site $SiteCode through $ProviderServer" 'PASS'
}

function Get-ApplicationFolderNames {
    $names = [System.Collections.Generic.List[string]]::new()
    $names.Add('')

    function Add-ApplicationFolderChildren {
        param(
            [Parameter(Mandatory)][string]$ParentPath,
            [string]$RelativeParent = ''
        )

        $children = @(Get-CMFolder -ParentFolderPath $ParentPath -ErrorAction Stop)
        foreach ($child in $children) {
            $name = [string](Get-SafePropertyValue -InputObject $child -PropertyName @('Name','FolderName'))
            if ([string]::IsNullOrWhiteSpace($name)) { continue }

            $relativePath = if ($RelativeParent) { "$RelativeParent\$name" } else { $name }
            if (-not $names.Contains($relativePath)) { $names.Add($relativePath) }
            Add-ApplicationFolderChildren -ParentPath "Application\$relativePath" -RelativeParent $relativePath
        }
    }

    try {
        Add-ApplicationFolderChildren -ParentPath 'Application'
    }
    catch {
        Write-WorkbenchLog "Application folder discovery warning: $($_.Exception.Message)" 'WARN'
    }

    return @($names | Sort-Object -Unique)
}

function Get-ComboValue {
    param([Parameter(Mandatory)]$Combo)
    if ($null -ne $Combo.SelectedItem) {
        if ($Combo.SelectedItem -is [System.Windows.Controls.ComboBoxItem]) { return [string]$Combo.SelectedItem.Content }
        return [string]$Combo.SelectedItem
    }
    return [string]$Combo.Text
}

function Get-QueueItemValue {
    param(
        [object]$Item,
        [Parameter(Mandatory)][string]$Name,
        [object]$Default = ''
    )
    if ($null -eq $Item) { return $Default }
    $property = $Item.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    return $property.Value
}

function Initialize-QueueItemExeProperties {
    param([object]$Item)
    if ($null -eq $Item) { return }
    $defaults = [ordered]@{
        InstallerFramework = $(if ((Get-QueueItemValue -Item $Item -Name 'InstallerType' -Default '') -eq 'MSI') { 'Windows Installer' } else { 'Unknown or custom EXE' })
        CommandConfidence = $(if ((Get-QueueItemValue -Item $Item -Name 'InstallerType' -Default '') -eq 'MSI') { 'Verified' } else { 'Unknown' })
        CommandGuidance = ''
        ExeCommandsConfirmed = $false
        IconMode = 'None'
        IconPath = ''
        ExtractedIconPath = ''
        IconSource = 'Unavailable'
        IconQuality = ''
        IconWidth = 0
        IconHeight = 0
    }
    foreach ($entry in $defaults.GetEnumerator()) {
        if ($null -eq $Item.PSObject.Properties[$entry.Key]) {
            $Item | Add-Member -NotePropertyName $entry.Key -NotePropertyValue $entry.Value -Force
        }
    }
}

function Get-QueueItemValidationFingerprint {
    param([Parameter(Mandatory)][object]$Item)

    $values = @(
        [string]$Item.Path,
        [string]$Item.AdministrativeName,
        [string]$Item.LocalizedName,
        [string]$Item.PublisherOverride,
        [string]$Item.VersionOverride,
        [string]$Item.Description,
        [string]$Item.Comments,
        [string]$Item.InstallCommand,
        [string]$Item.UninstallCommand,
        [string]$Item.DetectionType,
        [string]$Item.DetectionPath,
        [string]$Item.DetectionFileName,
        [string]$Item.RegistryHive,
        [string]$Item.RegistryKey,
        [string]$Item.RegistryValueName,
        [string]$Item.DetectionScript,
        [string]$Item.InstallerType,
        [string]$Item.ExeCommandsConfirmed,
        [string](Get-QueueItemValue -Item $Item -Name 'IconMode' -Default 'None'),
        [string](Get-QueueItemValue -Item $Item -Name 'IconPath' -Default ''),
        [string]$Item.DeploymentAction,
        [string]$Item.Collection
    )
    $payload = [string]::Join([char]31, $values)
    $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-','')
    }
    finally { $sha.Dispose() }
}

function Refresh-DistributionTargets {
    if (-not $script:State.Connected) { return }
    $mode = Get-ComboValue -Combo $script:Controls.DistributionModeCombo
    try {
        if ($mode -eq 'Distribution Point') {
            $targets = @(Get-CMDistributionPoint | ForEach-Object {
                foreach ($propertyName in 'ServerName','SiteSystemServerName','Name','NetworkOSPath','NALPath','Identity') {
                    $value = Get-SafePropertyValue -InputObject $_ -PropertyName @($propertyName)
                    if ($value) {
                        $text = [string]$value
                        if ($propertyName -in @('NetworkOSPath','NALPath')) { $text = $text.TrimStart('\') }
                        if ($text) { $text; break }
                    }
                }
            } | Where-Object { $_ } | Sort-Object -Unique)
        }
        else {
            $targets = @(Get-CMDistributionPointGroup | Select-Object -ExpandProperty Name | Where-Object { $_ } | Sort-Object -Unique)
        }
        $script:Controls.DistributionTargetCombo.ItemsSource = $targets
        $script:State.DpRefresh = "PASS ($($targets.Count))"
        if ($targets.Count -eq 1) {
            $script:Controls.DistributionTargetCombo.SelectedIndex = 0
        }
        Write-WorkbenchLog "Loaded $($targets.Count) $mode target(s)." 'PASS'
    }
    catch {
        $script:State.DpRefresh = "FAIL: $($_.Exception.Message)"
        $script:Controls.DistributionTargetCombo.ItemsSource = @()
        Write-WorkbenchLog "Distribution target discovery failed: $($_.Exception.Message)" 'ERROR'
    }
}

function Refresh-MecmTargets {
    try {
        $folderNames = @(Get-ApplicationFolderNames)
        $script:Controls.FolderCombo.ItemsSource = $folderNames
        $script:State.FolderRefresh = "PASS ($($folderNames.Count))"
        if ($folderNames.Count -eq 1) { $script:Controls.FolderCombo.SelectedIndex = 0 }
        Write-WorkbenchLog "Loaded $($folderNames.Count) Application folder(s)." 'PASS'
    }
    catch {
        $script:State.FolderRefresh = "FAIL: $($_.Exception.Message)"
        Write-WorkbenchLog "Application folder discovery failed: $($_.Exception.Message)" 'ERROR'
    }

    try {
        $collections = @(Get-CMDeviceCollection | Select-Object -ExpandProperty Name | Where-Object { $_ } | Sort-Object -Unique)
        $script:State.DeviceCollections = $collections
        foreach ($item in @($script:State.BatchItems)) {
            if ($item.PSObject.Properties['CollectionChoices']) { $item.CollectionChoices = @($collections) }
        }
        $script:State.CollectionRefresh = "PASS ($($collections.Count))"
        Write-WorkbenchLog "Loaded $($collections.Count) device collection(s)." 'PASS'
    }
    catch {
        $script:State.CollectionRefresh = "FAIL: $($_.Exception.Message)"
        Write-WorkbenchLog "Device collection discovery failed: $($_.Exception.Message)" 'ERROR'
    }

    if ($script:Controls.DistributionModeCombo.SelectedIndex -lt 0) { $script:Controls.DistributionModeCombo.SelectedIndex = 0 }
    if ($script:Controls.DetectionTypeCombo.SelectedIndex -lt 0) { $script:Controls.DetectionTypeCombo.SelectedIndex = 0 }
    if ($script:Controls.RegistryHiveCombo.SelectedIndex -lt 0) { $script:Controls.RegistryHiveCombo.SelectedIndex = 0 }
    Refresh-DistributionTargets
}

function Test-IsLocalComputerName {
    param([Parameter(Mandatory)][string]$ComputerName)
    $names = @(
        '.', 'localhost',
        $env:COMPUTERNAME,
        ([System.Net.Dns]::GetHostName())
    ) | Where-Object { $_ } | ForEach-Object { $_.ToString().ToLowerInvariant() }
    try {
        $names += ([System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName.ToLowerInvariant())
    } catch { }
    return $names -contains $ComputerName.TrimStart('\').ToLowerInvariant()
}

function Get-LocalSourceProvisionPlan {
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -notmatch '^\\\\([^\\]+)\\([^\\]+)(?:\\(.*))?$') { return $null }
    $server = $matches[1]
    $share = $matches[2]
    $relative = $matches[3]
    if (-not (Test-IsLocalComputerName -ComputerName $server)) { return $null }
    if ($share -ne 'MECMSources$') { return $null }
    [pscustomobject]@{
        Server = $server
        ShareName = $share
        LocalRoot = $script:State.LocalSourceBackingRoot
        RelativePath = $relative
        LocalTarget = if ($relative) { Join-Path $script:State.LocalSourceBackingRoot $relative } else { $script:State.LocalSourceBackingRoot }
    }
}

function Ensure-SourceRoot {
    param([Parameter(Mandatory)][string]$Path)
    if (Test-FileSystemPath -Path $Path) { return }

    $plan = Get-LocalSourceProvisionPlan -Path $Path
    if ($plan) {
        if (-not (Test-FileSystemPath -Path $plan.LocalRoot)) {
            New-FileSystemDirectory -Path $plan.LocalRoot | Out-Null
            Write-WorkbenchLog "Created local content source backing folder $($plan.LocalRoot)" 'PASS'
        }
        $share = Get-SmbShare -Name $plan.ShareName -ErrorAction SilentlyContinue
        if (-not $share) {
            New-SmbShare -Name $plan.ShareName -Path $plan.LocalRoot -FullAccess 'BUILTIN\Administrators' -ReadAccess 'Authenticated Users' -ErrorAction Stop | Out-Null
            Write-WorkbenchLog "Created local SMB share \$($plan.Server)\$($plan.ShareName) backed by $($plan.LocalRoot)" 'PASS'
        }
        if (-not (Test-FileSystemPath -Path $plan.LocalTarget)) {
            New-FileSystemDirectory -Path $plan.LocalTarget | Out-Null
            Write-WorkbenchLog "Created local content source target $($plan.LocalTarget)" 'PASS'
        }
        if (-not (Test-FileSystemPath -Path $Path)) {
            throw "The local source folder/share was created, but the UNC path is still not reachable: $Path"
        }
        return
    }

    $parent = Get-FileSystemParentPath -Path $Path
    if (-not $parent -or -not (Test-FileSystemPath -Path $parent -PathType Container)) {
        throw "The source path parent is not reachable and cannot be provisioned safely by this workbench: $parent"
    }
    New-FileSystemDirectory -Path $Path | Out-Null
    Write-WorkbenchLog "Created content source root $Path" 'PASS'
}


function Set-CurrentInstaller {
    param(
        [Parameter(Mandatory)][string]$Path,
        [object]$Metadata,
        [switch]$SuppressMetadataLog
    )
    $script:State.InstallerPath = $Path
    $script:State.InstallerMetadata = if ($null -ne $Metadata) { $Metadata } else { Get-InstallerMetadata -Path $Path }
    $script:State.MsiMetadata = $script:State.InstallerMetadata
    $script:State.InstallerType = [string]$script:State.InstallerMetadata.InstallerType
    $m = $script:State.InstallerMetadata
    $script:State.PreviewBusy = $true
    try {
        $script:Controls.InstallerText.Text = $m.FullPath
        $script:Controls.AdminNameText.Text = $m.ProductName
        $script:Controls.LocalizedNameText.Text = $m.ProductName
        $script:Controls.PublisherText.Text = $m.Manufacturer
        $script:Controls.VersionText.Text = $m.ProductVersion
        $script:Controls.ProductCodeText.Text = if ($m.InstallerType -eq 'MSI') { $m.ProductCode } else { "$($m.Framework) | $($m.CommandConfidence)" }
        $script:Controls.HashText.Text = $m.Sha256
        $script:Controls.SignatureText.Text = "$($m.Signature) $($m.Signer)".Trim()
        $script:Controls.DescriptionText.Text = "$($m.ProductName) $($m.ProductVersion)"
        $script:Controls.InstallerProfileText.Text = if ($m.InstallerType -eq 'EXE') { "EXE profile: $($m.Framework) | command confidence: $($m.CommandConfidence) | suggested name source: $($m.NameSource). $($m.CommandGuidance)" } else { 'MSI profile: Windows Installer metadata; default commands are verified and technician-editable.' }
        $script:Controls.CommandApprovalPanel.Visibility = if ($m.InstallerType -eq 'EXE') { 'Visible' } else { 'Collapsed' }
        $script:Controls.ExeValidationRequirementText.Visibility = if ($m.InstallerType -eq 'EXE') { 'Visible' } else { 'Collapsed' }
    }
    finally { $script:State.PreviewBusy = $false }
    $script:State.LastValidatedPath = $null
    $script:State.LastValidationPassed = $false
    if ($script:Controls.SelectedPreviewText) { $script:Controls.SelectedPreviewText.Text = "Selected package: $($m.ProductName)  $($m.ProductVersion) [$($m.InstallerType)]" }
    if (-not $SuppressMetadataLog) {
        Write-WorkbenchLog "Loaded $($m.InstallerType) metadata for $($m.FileName); suggested application name $($m.ProductName) from $($m.NameSource); version $($m.ProductVersion); profile $($m.Framework); command confidence $($m.CommandConfidence)" 'PASS'
        if ($m.InstallerType -eq 'EXE' -and -not [string]::IsNullOrWhiteSpace([string]$m.RejectedProductName)) {
            Write-WorkbenchLog "Ignored embedded ProductName '$($m.RejectedProductName)': $($m.NameRejectionReason)" 'WARN'
        }
    }
}


function Refresh-BatchGrid {
    if (-not $script:Controls.BatchGrid) { return }
    $selectedPath = $null
    if ($script:State.CurrentQueueItem) { $selectedPath = $script:State.CurrentQueueItem.Path }
    elseif ($script:Controls.BatchGrid.SelectedItem) { $selectedPath = $script:Controls.BatchGrid.SelectedItem.Path }

    $items = @($script:State.BatchItems)
    foreach ($item in $items) {
        if ($item.PSObject.Properties['CollectionChoices']) { $item.CollectionChoices = @($script:State.DeviceCollections) }
    }
    foreach ($grid in @($script:Controls.BatchGrid,$script:Controls.ReviewQueueGrid,$script:Controls.DeploymentTypeQueueGrid)) {
        if (-not $grid) { continue }
        $grid.ItemsSource = $null
        $grid.ItemsSource = $items
    }

    if ($selectedPath) {
        $match = @($script:State.BatchItems | Where-Object { $_.Path -eq $selectedPath } | Select-Object -First 1)
        if ($match.Count -gt 0) {
            $script:Controls.BatchGrid.SelectedItem = $match[0]
            if ($script:Controls.ReviewQueueGrid) { $script:Controls.ReviewQueueGrid.SelectedItem = $match[0] }
            if ($script:Controls.DeploymentTypeQueueGrid) { $script:Controls.DeploymentTypeQueueGrid.SelectedItem = $match[0] }
            $script:State.CurrentQueueItem = $match[0]
        }
    }
    $count = $script:State.BatchItems.Count
    $script:Controls.BatchCountText.Text = "$count package(s) queued"
    Update-LiveQueueStatus
    Update-ActionAvailability
}

function Add-InstallerToBatch {
    param([Parameter(Mandatory)][string]$Path)
    $existing = @($script:State.BatchItems | Where-Object { $_.Path -eq $Path })
    if ($existing.Count -gt 0) { return }
    try {
        $m = Get-InstallerMetadata -Path $Path
        $commands = Get-DefaultInstallerCommands -Metadata $m
        $icon = Get-InstallerIconRecommendation -Path $Path -InstallerType $m.InstallerType -Sha256 $m.Sha256
        $defaultDetection = if ($m.InstallerType -eq 'MSI') { 'MSI product code' } else { 'File exists' }
        $detail = if ($m.InstallerType -eq 'MSI') { 'MSI metadata extracted' } else { "EXE profile: $($m.Framework); commands $($m.CommandConfidence.ToLowerInvariant())" }
        [void]$script:State.BatchItems.Add([pscustomobject]@{
            Status='Ready'; Application=$m.ProductName; Version=$m.ProductVersion; DeploymentAction='Import only'; Collection='Not applicable';
            Publisher=$m.Manufacturer; File=$m.FileName; Path=$Path; Detail=$detail; Metadata=$m; InstallerType=$m.InstallerType;
            InstallerFramework=$m.Framework; CommandConfidence=$m.CommandConfidence; CommandGuidance=$m.CommandGuidance; ExeCommandsConfirmed=$false; NameSource=$m.NameSource;
            AdministrativeName=$m.ProductName; LocalizedName=$m.ProductName; PublisherOverride=$m.Manufacturer; VersionOverride=$m.ProductVersion;
            Description=("$($m.ProductName) $($m.ProductVersion)"); Comments='';
            InstallCommand=$commands.Install; UninstallCommand=$commands.Uninstall; DetectionType=$defaultDetection;
            DetectionPath=''; DetectionFileName=''; RegistryHive='LocalMachine'; RegistryKey=''; RegistryValueName=''; DetectionScript=''; CollectionChoices=@($script:State.DeviceCollections);
            IconMode=$icon.IconMode; IconPath=$icon.IconPath; ExtractedIconPath=$icon.ExtractedIconPath; IconSource=$icon.IconSource; IconQuality=$icon.IconQuality; IconWidth=$icon.IconWidth; IconHeight=$icon.IconHeight;
            ValidationState='Not validated'; ValidationTimestamp=$null; ValidationFingerprint=$null
        })
    }
    catch {
        [void]$script:State.BatchItems.Add([pscustomobject]@{
            Status='Blocked'; Application=[IO.Path]::GetFileNameWithoutExtension($Path); Version=''; DeploymentAction='Import only'; Collection='Not applicable';
            Publisher=''; File=[IO.Path]::GetFileName($Path); Path=$Path; Detail=$_.Exception.Message; Metadata=$null; InstallerType=[IO.Path]::GetExtension($Path).TrimStart('.').ToUpperInvariant();
            InstallerFramework='Unknown'; CommandConfidence='Unknown'; CommandGuidance='Inspection failed.'; ExeCommandsConfirmed=$false; NameSource='raw file name';
            AdministrativeName=[IO.Path]::GetFileNameWithoutExtension($Path); LocalizedName=[IO.Path]::GetFileNameWithoutExtension($Path); PublisherOverride=''; VersionOverride=''; Description=''; Comments='';
            InstallCommand=''; UninstallCommand=''; DetectionType='File exists'; DetectionPath=''; DetectionFileName='';
            RegistryHive='LocalMachine'; RegistryKey=''; RegistryValueName=''; DetectionScript=''; CollectionChoices=@($script:State.DeviceCollections);
            IconMode='None'; IconPath=''; ExtractedIconPath=''; IconSource='Unavailable'; IconQuality='Inspection failed'; IconWidth=0; IconHeight=0;
            ValidationState='Blocked'; ValidationTimestamp=$null; ValidationFingerprint=$null
        })
    }
    Refresh-BatchGrid
}


function Invoke-ItemRollback {
    # Rollback must be safe even when validation failed before an application
    # object was created.  Under StrictMode, reading a missing OrderedDictionary
    # key as a property throws PropertyNotFoundException and can mask the real
    # intake failure.
    $createdName = $null
    if ($script:State.Contains('LastCreatedApplicationName')) {
        $createdName = [string]$script:State['LastCreatedApplicationName']
    }

    if ([string]::IsNullOrWhiteSpace($createdName)) { return }

    try {
        $partialApp = Get-CMApplication -Name $createdName -Fast -ErrorAction SilentlyContinue
        if ($partialApp) {
            Remove-CMApplication -InputObject $partialApp -Force -ErrorAction Stop
            Write-WorkbenchLog "Rolled back partially created application $createdName. Source files were retained for retry." 'WARN'
        }
    }
    catch {
        # Rollback errors are logged but never replace the original item failure.
        Write-WorkbenchLog "Automatic rollback failed for ${createdName}: $($_.Exception.Message)" 'ERROR'
    }
    finally {
        $script:State['LastCreatedApplicationName'] = $null
    }
}

function Invoke-ValidateAll {
    if (-not $script:State.Connected) { throw 'Connect to MECM before validating the queue.' }
    $items = @($script:State.BatchItems)
    if ($items.Count -eq 0) { throw 'The intake queue is empty.' }

    Save-CurrentQueueItemSettings
    $originalItem = $script:State.CurrentQueueItem
    $passed = 0; $failed = 0; $blocked = 0; $warningCount = 0
    $passedItems = New-Object System.Collections.Generic.List[string]
    $warningItems = New-Object System.Collections.Generic.List[object]
    $failedItems = New-Object System.Collections.Generic.List[object]
    $blockedItems = New-Object System.Collections.Generic.List[string]
    $script:Controls.ValidationStatusText.Text = "Validating all $($items.Count) queued packages..."
    $script:Controls.ValidationStatusText.Foreground = '#5F6F7F'
    try {
        foreach ($item in $items) {
            if ($item.Status -eq 'Blocked' -or -not $item.Metadata) {
                $item.ValidationState = 'Blocked'
                $blocked++
                $blockedItems.Add([string]$item.Application) | Out-Null
                continue
            }
            Select-QueueItem -Item $item -OriginGrid $null
            $checks = Test-IntakePlan
            $item.ValidationTimestamp = Get-Date
            if ($checks.Status -contains 'FAIL') {
                $item.ValidationState = 'Failed validation'
                $item.ValidationFingerprint = $null
                $item.Status = 'Ready'
                $failureChecks = @($checks | Where-Object Status -eq 'FAIL')
                $failureText = @($failureChecks | ForEach-Object { "$($_.Check): $($_.Detail)" })
                $item.Detail = if ($failureText.Count) { "Validation failed: $($failureText -join '; ')" } else { 'Validation failed' }
                $failed++
                $failedItems.Add([pscustomobject]@{ Application=[string]$item.Application; Checks=$failureChecks }) | Out-Null
                Write-WorkbenchLog ("Validation failed for {0}: {1}" -f [string]$item.Application, $(if($failureText.Count){$failureText -join '; '}else{'No failure detail returned'})) 'WARN'
            } else {
                $warningChecks = @($checks | Where-Object Status -eq 'WARN')
                $item.ValidationState = 'Validated'
                $item.ValidationFingerprint = Get-QueueItemValidationFingerprint -Item $item
                $item.Status = 'Validated'
                if ($warningChecks.Count -gt 0) {
                    $warningText = @($warningChecks | ForEach-Object { "$($_.Check): $($_.Detail)" })
                    $item.Detail = "Pre-commit validation passed with warning: $($warningText -join '; ')"
                    $warningCount++
                    $warningItems.Add([pscustomobject]@{ Application=[string]$item.Application; Checks=$warningChecks }) | Out-Null
                    Write-WorkbenchLog ("Validation warning for {0}: {1}" -f [string]$item.Application, ($warningText -join '; ')) 'WARN'
                } else {
                    $item.Detail = 'Pre-commit validation passed'
                }
                $passed++
                $passedItems.Add([string]$item.Application) | Out-Null
            }
            Refresh-BatchGrid
            Invoke-UiRefresh
        }
    }
    finally {
        if ($originalItem -and $script:State.BatchItems -contains $originalItem) { Select-QueueItem -Item $originalItem -OriginGrid $null }
        elseif ($items.Count -gt 0) { Select-QueueItem -Item $items[0] -OriginGrid $null }
    }

    $allPassed = ($failed -eq 0 -and $blocked -eq 0)
    $script:Controls.ValidationStatusText.Text = "Validate All complete: $passed passed ($warningCount with warnings), $failed failed, $blocked blocked. Review warnings and correct every failure before processing."
    $script:Controls.ValidationStatusText.Foreground = if ($allPassed) { '#2F7D4A' } else { '#A66722' }

    $summaryLines = New-Object System.Collections.Generic.List[string]
    $summaryLines.Add("VALIDATE ALL SUMMARY") | Out-Null
    $summaryLines.Add("--------------------") | Out-Null
    $summaryLines.Add("Queued:  $($items.Count)") | Out-Null
    $summaryLines.Add("Passed:  $passed") | Out-Null
    $summaryLines.Add("Failed:  $failed") | Out-Null
    $summaryLines.Add("Blocked: $blocked") | Out-Null
    $summaryLines.Add("Warnings: $warningCount") | Out-Null
    if ($failedItems.Count -gt 0) {
        $summaryLines.Add('') | Out-Null
        $summaryLines.Add('FAILED APPLICATIONS') | Out-Null
        foreach ($failure in $failedItems) {
            $summaryLines.Add([string]$failure.Application) | Out-Null
            foreach ($check in @($failure.Checks)) { $summaryLines.Add("  - $($check.Check): $($check.Detail)") | Out-Null }
            $summaryLines.Add('') | Out-Null
        }
    }
    if ($warningItems.Count -gt 0) {
        $summaryLines.Add('WARNINGS - creation is allowed') | Out-Null
        foreach ($warning in $warningItems) {
            $summaryLines.Add([string]$warning.Application) | Out-Null
            foreach ($check in @($warning.Checks)) { $summaryLines.Add("  - $($check.Check): $($check.Detail)") | Out-Null }
            $summaryLines.Add('') | Out-Null
        }
    }
    if ($blockedItems.Count -gt 0) {
        $summaryLines.Add('') | Out-Null
        $summaryLines.Add('Blocked applications:') | Out-Null
        foreach ($name in $blockedItems) { $summaryLines.Add("  - $name") | Out-Null }
    }
    $summaryLines.Add('') | Out-Null
    $summaryLines.Add($(if ($allPassed -and $warningCount -gt 0) { 'All queued applications passed. Warnings are advisory; review them before processing.' } elseif ($allPassed) { 'All queued applications passed pre-commit validation.' } else { 'Correct every failed or blocked application before processing the queue. Warnings alone do not block creation.' })) | Out-Null
    $validationSummary = $summaryLines -join [Environment]::NewLine
    $script:Controls.ResultText.Text = $validationSummary

    Write-WorkbenchLog "Validate All completed. Passed=$passed Warnings=$warningCount Failed=$failed Blocked=$blocked" $(if($allPassed){'PASS'}else{'WARN'})
    Refresh-BatchGrid
    [System.Windows.MessageBox]::Show(
        $validationSummary,
        'Validate All Summary',
        'OK',
        $(if ($allPassed) { 'Information' } else { 'Warning' })
    ) | Out-Null
}

function Invoke-BatchIntake {
    if (-not $script:State.Connected) { throw 'Connect to MECM before processing the queue.' }
    $items = @($script:State.BatchItems)
    if ($items.Count -eq 0) { throw 'The intake queue is empty.' }
    $answer = [System.Windows.MessageBox]::Show("Process $($items.Count) queued installer package(s) sequentially using each package's deployment behavior and collection settings?",'Confirm batch intake','YesNo','Warning')
    if ($answer -ne 'Yes') { return }

    $success=0; $failed=0; $blocked=0; $cancelled=0; $skipped=0
    $script:State.CancelAfterCurrent = $false
    $script:State.CurrentBatchTotal = $items.Count
    $script:State.CurrentBatchIndex = 0
    Set-ProcessingUi -IsProcessing $true
    try {
        foreach ($item in $items) {
            $script:State.CurrentBatchIndex++
            if ($script:State.CancelAfterCurrent) {
                if ($item.Status -notin @('Success','Failed','Blocked')) { $item.Status='Cancelled'; $item.Detail='Not processed because cancellation was requested'; $cancelled++ }
                Update-ProcessingStatus -Stage 'Cancellation requested; marking remaining applications as cancelled.' -Item $item
                Refresh-BatchGrid
                continue
            }
            if ($item.Status -eq 'Blocked') { $blocked++; $item.Detail='Blocked before processing; review intake errors'; Refresh-BatchGrid; continue }
            if ($item.Status -eq 'Success') { $item.Detail='Already completed; skipped on this run'; $skipped++; continue }
            $item.Status='Processing'; $item.Detail='Validating package'
            Refresh-BatchGrid
            Update-ProcessingStatus -Stage 'Validating package and intake settings...' -StagePercent 5 -Item $item
            try {
                Select-QueueItem -Item $item -OriginGrid $null
                Update-Preview -FullValidation
                $item.Status='Validated'; $item.Detail='Validation passed; committing application'
                Refresh-BatchGrid
                Invoke-CreateApplication -BatchMode -BatchItem $item
                $item.Status='Success'
                $item.Detail=if($item.DeploymentAction -eq 'Available'){'Application created, distribution requested, and made Available'}else{'Application created and distribution requested; no deployment created'}
                $success++
            }
            catch {
                Write-WorkbenchLog $_.Exception.ToString() 'ERROR'
                Invoke-ItemRollback
                $item.Status='Failed'; $item.Detail=$_.Exception.Message
                $failed++
            }
            Refresh-BatchGrid
            $script:Controls.OverallProgressBar.Value = $script:State.CurrentBatchIndex
            Invoke-UiRefresh
        }
    }
    finally {
        Set-ProcessingUi -IsProcessing $false
        $script:State.CurrentBatchTotal = 0
        $script:State.CurrentBatchIndex = 0
    }
    $completed = $success + $failed + $blocked + $skipped + $cancelled
    $stopNote = if ($script:State.CancelAfterCurrent) { "`r`nStop reason: Operator requested cancellation; the active application finished or rolled back before the queue stopped." } else { "`r`nStop reason: Queue reached the end." }
    $failedItems = @($items | Where-Object { $_.Status -in @('Failed','Blocked') } | ForEach-Object { " - $($_.Application): $($_.Detail)" })
    $failureDetail = if ($failedItems.Count -gt 0) { "`r`n`r`nItems requiring attention:`r`n$($failedItems -join "`r`n")" } else { '' }
    $script:State.LastBatchSummary = [pscustomobject]@{ Total=$items.Count; Completed=$completed; Success=$success; Failed=$failed; Blocked=$blocked; Skipped=$skipped; Cancelled=$cancelled; CancelRequested=$script:State.CancelAfterCurrent }
    $script:Controls.ResultText.Text = "BATCH SUMMARY`r`n`r`nTotal queued: $($items.Count)`r`nAccounted for: $completed`r`nSucceeded: $success`r`nFailed: $failed`r`nBlocked: $blocked`r`nSkipped: $skipped`r`nCancelled: $cancelled$stopNote$failureDetail`r`n`r`nLog: $script:LogFile`r`nManifests: $($script:State.ManifestRoot)"
    Write-WorkbenchLog "Batch summary: Total=$($items.Count) Success=$success Failed=$failed Blocked=$blocked Skipped=$skipped Cancelled=$cancelled" $(if($failed -eq 0 -and $blocked -eq 0){'PASS'}else{'WARN'})
    $script:Controls.Tabs.SelectedIndex = 4
}

function Get-EffectiveSourceRoot {
    $value = ''
    if ($script:Controls -and $script:Controls.SourceRootText) {
        $value = [string]$script:Controls.SourceRootText.Text
    }
    if ([string]::IsNullOrWhiteSpace($value)) {
        $value = [string]$script:State.SourceRoot
        if ($script:Controls -and $script:Controls.SourceRootText) {
            $script:State.PreviewBusy = $true
            try { $script:Controls.SourceRootText.Text = $value }
            finally { $script:State.PreviewBusy = $false }
        }
    }
    return $value.Trim()
}

function Get-DistributionPointGroupMembers {
    param([Parameter(Mandatory)][string]$GroupName)

    # ConfigMgr builds do not consistently include a
    # Get-CMDistributionPointGroupMember cmdlet. The supported
    # Get-CMDistributionPoint command can query by group name.
    return @(Get-CMDistributionPoint -DistributionPointGroupName $GroupName -ErrorAction Stop)
}

function Update-CommandApprovalPanelVisual {
    if (-not $script:Controls -or -not $script:Controls.CommandApprovalPanel) { return }
    $item = $script:State.CurrentQueueItem
    if (-not $item -or [string](Get-QueueItemValue -Item $item -Name 'InstallerType' -Default '') -ne 'EXE') {
        $script:Controls.CommandApprovalPanel.Visibility = 'Collapsed'
        return
    }

    $approved = [bool]$script:Controls.CommandApprovalCheck.IsChecked
    $script:Controls.CommandApprovalPanel.Visibility = 'Visible'
    $script:Controls.CommandApprovalPanel.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if($approved){'#E8F5EC'}else{'#FFF5DA'}))
    $script:Controls.CommandApprovalPanel.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if($approved){'#72B787'}else{'#E7C66B'}))
    $script:Controls.CommandApprovalHeading.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString($(if($approved){'#245F37'}else{'#664B00'}))
    $script:Controls.CommandApprovalHeading.Text = if($approved){'Technician Approval Complete'}else{'Technician Approval Required'}
}

function Update-ExeReadinessGuidance {
    Update-CommandApprovalPanelVisual
    if (-not $script:Controls -or -not $script:Controls.ExeValidationRequirementText) { return }
    $item = $script:State.CurrentQueueItem
    if (-not $item -or [string](Get-QueueItemValue -Item $item -Name 'InstallerType' -Default '') -ne 'EXE') {
        $script:Controls.ExeValidationRequirementText.Visibility = 'Collapsed'
        return
    }

    $installReady = -not [string]::IsNullOrWhiteSpace($script:Controls.InstallCommandText.Text)
    $uninstallReady = -not [string]::IsNullOrWhiteSpace($script:Controls.UninstallCommandText.Text)
    $approved = [bool]$script:Controls.CommandApprovalCheck.IsChecked
    $detectionType = Get-ComboValue -Combo $script:Controls.DetectionTypeCombo
    $detectionReady = switch ($detectionType) {
        'File exists' { (-not [string]::IsNullOrWhiteSpace($script:Controls.DetectionPathText.Text)) -and (-not [string]::IsNullOrWhiteSpace($script:Controls.DetectionFileNameText.Text)) }
        'Registry key/value exists' { -not [string]::IsNullOrWhiteSpace($script:Controls.RegistryKeyText.Text) }
        'PowerShell script' {
            $text = $script:Controls.DetectionScriptText.Text
            if ([string]::IsNullOrWhiteSpace($text)) { $false }
            else {
                $tokens=$null; $errors=$null
                [void][System.Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
                @($errors).Count -eq 0
            }
        }
        default { $false }
    }

    $installState = if($installReady){'Ready'}else{'Missing'}
    $uninstallState = if($uninstallReady){'Ready'}else{'Optional - blank will produce a validation warning'}
    $approvalState = if($approved){'Ready'}else{'Missing'}
    $detectionState = if($detectionReady){'Ready'}else{'Missing or incomplete'}
    $script:Controls.ExeValidationRequirementText.Text = "EXE readiness - Install command: $installState | Uninstall command: $uninstallState | Technician approval: $approvalState | Detection: $detectionState"
    $requiredReady = $installReady -and $approved -and $detectionReady
    $script:Controls.ExeValidationRequirementText.Foreground = if($requiredReady){'#2F7D4A'}else{'#A66722'}
    $script:Controls.ExeValidationRequirementText.Visibility = 'Visible'
}

function Test-IntakePlan {
    Save-CurrentQueueItemSettings
    $checks = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Name,[bool]$Passed,[string]$Detail) {
        $checks.Add([pscustomobject]@{ Check=$Name; Status=if($Passed){'PASS'}else{'FAIL'}; Detail=$Detail })
    }
    function Add-Warning([string]$Name,[string]$Detail) {
        $checks.Add([pscustomobject]@{ Check=$Name; Status='WARN'; Detail=$Detail })
    }

    Add-Check 'ConfigurationManager module imported' $script:State.ModuleImported $(if($script:State.ModuleImported){'Imported'}else{'Not imported'})
    Add-Check 'CMSite drive available' $script:State.SiteDriveReady $(if($script:State.SiteDriveReady){"$($script:State.SiteCode):"}else{'Not available'})
    Add-Check 'Connected to MECM' $script:State.SiteConnected $(if($script:State.SiteConnected){"$($script:State.SiteCode) via $($script:State.ProviderServer)"}else{'Not connected'})
    Add-Check 'Application folders loaded' ($script:State.FolderRefresh -like 'PASS*') $script:State.FolderRefresh
    Add-Check 'Distribution targets loaded' ($script:State.DpRefresh -like 'PASS*') $script:State.DpRefresh
    $currentItem = $script:State.CurrentQueueItem
    $effectiveItem = $currentItem
    $deploymentAction = if ($currentItem) { [string]$currentItem.DeploymentAction } else { 'Import only' }
    if ($deploymentAction -eq 'Available') {
        Add-Check 'Device collections loaded' ($script:State.CollectionRefresh -like 'PASS*') $script:State.CollectionRefresh
    } else {
        $checks.Add([pscustomobject]@{ Check='Device collections loaded'; Status='N/A'; Detail='Not required for Import only' })
    }
    Add-Check 'Installer selected' ([bool]$script:State.InstallerPath) $script:State.InstallerPath
    Add-Check 'Installer exists' ($script:State.InstallerPath -and (Test-FileSystemPath -Path $script:State.InstallerPath -PathType Leaf)) ''
    Add-Check 'Application name populated' (-not [string]::IsNullOrWhiteSpace($script:Controls.AdminNameText.Text)) $script:Controls.AdminNameText.Text
    Add-Check 'Software Center name populated' (-not [string]::IsNullOrWhiteSpace($script:Controls.LocalizedNameText.Text)) $script:Controls.LocalizedNameText.Text
    Add-Check 'Version populated' (-not [string]::IsNullOrWhiteSpace($script:Controls.VersionText.Text)) $script:Controls.VersionText.Text
    $sourceRoot = Get-EffectiveSourceRoot
    $sourceExists = Test-FileSystemPath -Path $sourceRoot -PathType Container
    $sourceParent = Get-FileSystemParentPath -Path $sourceRoot
    $parentReachable = $sourceParent -and (Test-FileSystemPath -Path $sourceParent -PathType Container)
    $localProvisionPlan = Get-LocalSourceProvisionPlan -Path $sourceRoot
    $canCreateSource = $script:Controls.AutoCreateSourceCheck.IsChecked -and ($parentReachable -or $null -ne $localProvisionPlan)
    $sourceDetail = if($sourceExists){
        $sourceRoot
    } elseif($canCreateSource -and $localProvisionPlan) {
        "Creatable locally: $($localProvisionPlan.LocalTarget); share $($localProvisionPlan.ShareName) will be created if needed"
    } elseif($canCreateSource) {
        "Creatable; parent reachable: $sourceParent"
    } else {
        "Cannot create; parent unavailable: $sourceParent"
    }
    Add-Check 'Source root available' ($sourceExists -or $canCreateSource) $sourceDetail
    $distributionMode = Get-ComboValue -Combo $script:Controls.DistributionModeCombo
    $distributionTarget = Get-ComboValue -Combo $script:Controls.DistributionTargetCombo
    $distributionSelected = -not [string]::IsNullOrWhiteSpace($distributionTarget)
    Add-Check 'Distribution target selected' $distributionSelected ("{0}: {1}" -f $distributionMode,$distributionTarget)
    $iconPath = if ($currentItem) { [string](Get-QueueItemValue -Item $currentItem -Name 'IconPath' -Default '') } else { '' }
    $iconMode = if ($currentItem) { [string](Get-QueueItemValue -Item $currentItem -Name 'IconMode' -Default 'None') } else { 'None' }
    $iconQuality = if ($currentItem) { [string](Get-QueueItemValue -Item $currentItem -Name 'IconQuality' -Default '') } else { '' }
    if ($iconMode -eq 'None' -or [string]::IsNullOrWhiteSpace($iconPath)) {
        Add-Warning 'Software Center icon' 'No icon selected; application creation can continue without one.'
    } elseif (-not (Test-FileSystemPath -Path $iconPath -PathType Leaf)) {
        Add-Warning 'Software Center icon' "Selected icon file is unavailable: $iconPath. Creation will continue without an icon."
    } elseif ($iconQuality -eq 'Low resolution') {
        Add-Warning 'Software Center icon' "Icon is available but low resolution: $iconPath"
    } else {
        $checks.Add([pscustomobject]@{ Check='Software Center icon'; Status='PASS'; Detail=$iconPath })
    }

    if ($distributionSelected -and $script:State.Connected) {
        if ($distributionMode -eq 'DP Group') {
            try {
                $groupMembers = @(Get-DistributionPointGroupMembers -GroupName $distributionTarget)
                $memberNames = @($groupMembers | ForEach-Object {
                    foreach ($propertyName in 'ServerName','SiteSystemServerName','Name','NetworkOSPath','NALPath','Identity') {
                        $value = Get-SafePropertyValue -InputObject $_ -PropertyName @($propertyName)
                        if ($value) { [string]$value; break }
                    }
                } | Where-Object { $_ })
                $memberCount = $groupMembers.Count
                $detail = if ($memberCount -gt 0) {
                    if ($memberNames.Count -gt 0) { "$memberCount member(s): $($memberNames -join ', ')" } else { "$memberCount member(s)" }
                } else {
                    'Selected DP group has no members. Add a DP to the group or choose an individual Distribution Point.'
                }
                Add-Check 'Distribution target usable' ($memberCount -gt 0) $detail
            }
            catch {
                Add-Check 'Distribution target usable' $false ("Unable to verify DP group membership: {0}" -f $_.Exception.Message)
            }
        }
        else {
            Add-Check 'Distribution target usable' $true ("Individual DP selected: {0}" -f $distributionTarget)
        }
    }

    $installCommand = if ($effectiveItem) { [string]$effectiveItem.InstallCommand } else { $script:Controls.InstallCommandText.Text.Trim() }
    $uninstallCommand = if ($effectiveItem) { [string]$effectiveItem.UninstallCommand } else { $script:Controls.UninstallCommandText.Text.Trim() }
    $iconPath = if ($effectiveItem) { [string](Get-QueueItemValue -Item $effectiveItem -Name 'IconPath' -Default '') } else { '' }
    $isExePackage = ($effectiveItem -and [string]$effectiveItem.InstallerType -eq 'EXE')
    Add-Check 'Install command' (-not [string]::IsNullOrWhiteSpace($installCommand)) $(if([string]::IsNullOrWhiteSpace($installCommand)){'Install command is blank'}else{$installCommand})
    if ($isExePackage) {
        if ([string]::IsNullOrWhiteSpace($uninstallCommand)) {
            Add-Warning 'Uninstall command' 'Uninstall command is blank. The deployment type can be created, but uninstall will not be available.'
        } else {
            Add-Check 'Uninstall command' $true $uninstallCommand
        }
        Add-Check 'EXE command approval' ([bool]$effectiveItem.ExeCommandsConfirmed) $(if([bool]$effectiveItem.ExeCommandsConfirmed){"Approved by technician; framework: $($effectiveItem.InstallerFramework); confidence: $($effectiveItem.CommandConfidence)"}else{"Technician approval is required; framework: $($effectiveItem.InstallerFramework); confidence: $($effectiveItem.CommandConfidence)"})
    } else {
        Add-Check 'Uninstall command' (-not [string]::IsNullOrWhiteSpace($uninstallCommand)) $(if([string]::IsNullOrWhiteSpace($uninstallCommand)){'Uninstall command is blank'}else{$uninstallCommand})
    }

    $detectionType = if ($effectiveItem) { [string]$effectiveItem.DetectionType } else { Get-ComboValue -Combo $script:Controls.DetectionTypeCombo }
    switch ($detectionType) {
        'MSI product code' {
            $isMsi = ($effectiveItem -and [string]$effectiveItem.InstallerType -eq 'MSI')
            $hasCode = $isMsi -and -not [string]::IsNullOrWhiteSpace([string]$script:State.MsiMetadata.ProductCode)
            Add-Check 'Detection method' $hasCode $(if($hasCode){"MSI product code: $($script:State.MsiMetadata.ProductCode)"}else{'MSI product-code detection is available only for MSI packages'})
        }
        'File exists' {
            $ok = (-not [string]::IsNullOrWhiteSpace($script:Controls.DetectionPathText.Text)) -and (-not [string]::IsNullOrWhiteSpace($script:Controls.DetectionFileNameText.Text))
            Add-Check 'Detection method' $ok $(if($ok){"File exists: $($script:Controls.DetectionPathText.Text)\$($script:Controls.DetectionFileNameText.Text)"}else{'File detection requires both a folder path and file name'})
        }
        'Registry key/value exists' {
            $ok = -not [string]::IsNullOrWhiteSpace($script:Controls.RegistryKeyText.Text)
            Add-Check 'Detection method' $ok $(if($ok){"$(Get-ComboValue -Combo $script:Controls.RegistryHiveCombo)\$($script:Controls.RegistryKeyText.Text)"}else{'Registry detection requires a key path'})
        }
        'PowerShell script' {
            $scriptText = $script:Controls.DetectionScriptText.Text
            $tokens = $null
            $errors = $null
            if (-not [string]::IsNullOrWhiteSpace($scriptText)) {
                [void][System.Management.Automation.Language.Parser]::ParseInput($scriptText,[ref]$tokens,[ref]$errors)
            }
            $ok = (-not [string]::IsNullOrWhiteSpace($scriptText)) -and (@($errors).Count -eq 0)
            Add-Check 'Detection method' $ok $(if($ok){'PowerShell detection script syntax valid'}else{'PowerShell detection script is blank or invalid'})
        }
        default { Add-Check 'Detection method' $false 'Select a supported detection method' }
    }

    if ($deploymentAction -eq 'Available') {
        $collectionValue = if ($currentItem) { [string]$currentItem.Collection } else { '' }
        Add-Check 'Software Center collection selected' (-not [string]::IsNullOrWhiteSpace($collectionValue)) $collectionValue
    } else {
        Add-Check 'Deployment behavior' $true 'Import only - no deployment will be created'
    }

    if ($script:State.Connected -and $script:State.MsiMetadata) {
        $duplicateProduct = $null
        $isMsiPackage = ($effectiveItem -and [string]$effectiveItem.InstallerType -eq 'MSI')
        $apps = @(Get-CMApplication -Fast -ErrorAction SilentlyContinue)
        foreach ($existingApp in $apps) {
            $existingName = if ($existingApp.LocalizedDisplayName) { [string]$existingApp.LocalizedDisplayName } elseif ($existingApp.Name) { [string]$existingApp.Name } else { $null }
            if (-not $existingName) { continue }
            if (-not $isMsiPackage) { continue }
            $deploymentTypes = @(Get-CMDeploymentType -ApplicationName $existingName -ErrorAction SilentlyContinue)
            foreach ($deploymentType in $deploymentTypes) {
                # Deployment-type objects differ across ConfigMgr builds and installer technologies.
                # Under StrictMode, reading a missing .ProductCode property throws and previously
                # aborted Preview/Validation. Only compare when a product-code property actually exists.
                $deploymentTypeProductCode = Get-SafePropertyValue -InputObject $deploymentType -PropertyName @('ProductCode','MsiProductCode')
                if ($deploymentTypeProductCode -and ([string]$deploymentTypeProductCode -eq [string]$script:State.MsiMetadata.ProductCode)) {
                    $duplicateProduct = $deploymentType
                    $duplicateProduct | Add-Member -NotePropertyName DetectedApplicationName -NotePropertyValue $existingName -Force
                    break
                }
            }
            if ($duplicateProduct) { break }
        }
        if ($isMsiPackage) { Add-Check 'Duplicate MSI product code' (-not $duplicateProduct) $(if($duplicateProduct){"Found in $($duplicateProduct.DetectedApplicationName)"}else{'Clear'}) }
        else { $checks.Add([pscustomobject]@{ Check='Duplicate MSI product code'; Status='N/A'; Detail='Not applicable to EXE deployment types' }) }
        $duplicateName = Get-CMApplication -Name $script:Controls.AdminNameText.Text -Fast -ErrorAction SilentlyContinue
        Add-Check 'Duplicate application name' (-not $duplicateName) $(if($duplicateName){'Application already exists'}else{'Clear'})
    }

    return $checks
}

function Update-Preview {
    param([switch]$FullValidation)
    if ($script:State.PreviewBusy) { return }
    Update-ExeReadinessGuidance

    $folder = [string]$script:Controls.FolderCombo.Text
    $appName = Normalize-MetadataText -Value $script:Controls.AdminNameText.Text
    $version = Normalize-MetadataText -Value $script:Controls.VersionText.Text
    $safePublisher = ConvertTo-SafeSourcePathComponent -Value $script:Controls.PublisherText.Text -Fallback 'Unknown Publisher'
    $sourceRootForPreview = Get-EffectiveSourceRoot
    if ([string]::IsNullOrWhiteSpace($sourceRootForPreview) -or
        [string]::IsNullOrWhiteSpace($appName) -or
        [string]::IsNullOrWhiteSpace($version)) {
        $destination = '[Complete installer metadata and content source to calculate destination]'
    }
    else {
        $safeAppName = ConvertTo-SafeSourcePathComponent -Value $appName -Fallback 'Unnamed Application'
        $safeVersion = ConvertTo-SafeSourcePathComponent -Value $version -Fallback 'Unknown Version'
        $destination = Join-Path $sourceRootForPreview (Join-Path $safePublisher (Join-Path $safeAppName $safeVersion))
    }

    $lines = @(
        "Preview applies to the currently selected queue item only.",
        "Queued packages: $($script:State.BatchItems.Count)",
        '',
        "Create application: $appName",
        "Software Center name: $($script:Controls.LocalizedNameText.Text)",
        "Install command: $($script:Controls.InstallCommandText.Text)",
        "Uninstall command: $($script:Controls.UninstallCommandText.Text)",
        "Detection method: $(Get-ComboValue -Combo $script:Controls.DetectionTypeCombo)",
        "Publisher: $($script:Controls.PublisherText.Text)",
        "Version: $version",
        "Copy installer content to: $destination",
        $(if($script:State.CurrentQueueItem -and (Get-QueueItemValue -Item $script:State.CurrentQueueItem -Name 'InstallerType' -Default '') -eq 'MSI'){"Create MSI deployment type using product code $($script:State.MsiMetadata.ProductCode)"}elseif($script:State.CurrentQueueItem){"Create EXE script deployment type; framework $(Get-QueueItemValue -Item $script:State.CurrentQueueItem -Name 'InstallerFramework' -Default 'Unknown or custom EXE'), command confidence $(Get-QueueItemValue -Item $script:State.CurrentQueueItem -Name 'CommandConfidence' -Default 'Unknown')"}else{'Select a queued installer to preview its deployment type.'}),
        "Application folder: $folder",
        "Distribute to $($script:Controls.DistributionModeCombo.Text): $($script:Controls.DistributionTargetCombo.Text)",
        $(if($script:State.CurrentQueueItem -and $script:State.CurrentQueueItem.DeploymentAction -eq 'Available'){"Create Available deployment to: $($script:State.CurrentQueueItem.Collection)"}else{'Deployment: Import only (staged in ConfigMgr; not shown in Software Center)'})
    )
    $script:Controls.PlanText.Text = $lines -join [Environment]::NewLine

    if ($FullValidation) {
        $script:Controls.ValidationStatusText.Text = 'Running full MECM validation...'
        $script:Controls.ValidationStatusText.Foreground = '#5F6F7F'
        $checks = Test-IntakePlan
        $script:Controls.ValidationGrid.ItemsSource = $checks
        $passed = -not ($checks.Status -contains 'FAIL')
        $warningChecks = @($checks | Where-Object Status -eq 'WARN')
        $script:State.LastValidatedPath = $script:State.InstallerPath
        $script:State.LastValidationPassed = $passed
        if ($script:State.CurrentQueueItem) {
            $script:State.CurrentQueueItem.ValidationState = if ($passed) { 'Validated' } else { 'Failed validation' }
            $script:State.CurrentQueueItem.ValidationTimestamp = Get-Date
            $script:State.CurrentQueueItem.ValidationFingerprint = if ($passed) { Get-QueueItemValidationFingerprint -Item $script:State.CurrentQueueItem } else { $null }
        }
        Update-ActionAvailability
        $script:Controls.ValidationStatusText.Text = if ($passed -and $warningChecks.Count -gt 0) { 'Selected package is ready for creation with warnings. Review the warning rows.' } elseif ($passed) { 'Selected package is ready for single-app creation.' } else { 'Selected package has validation failures.' }
        $script:Controls.ValidationStatusText.Foreground = if (-not $passed) { '#B42318' } elseif ($warningChecks.Count -gt 0) { '#A66722' } else { '#2F7D4A' }
    }
    else {
        # Preserve a completed validation when the operator selects an item that
        # already passed Validate Selected or Validate All. Selection refreshes
        # the preview, but must not silently discard the per-item validation
        # state and leave Create Selected Application disabled.
        $selectedItemIsValidated = ($script:State.CurrentQueueItem -and $script:State.CurrentQueueItem.ValidationState -eq 'Validated')
        if ($selectedItemIsValidated) {
            $script:State.LastValidatedPath = $script:State.InstallerPath
            $script:State.LastValidationPassed = $true
            $script:Controls.ValidationStatusText.Text = 'Selected package has passed validation and is ready for single-app creation.'
            $script:Controls.ValidationStatusText.Foreground = '#2F7D4A'
        }
        else {
            $script:State.LastValidatedPath = $null
            $script:State.LastValidationPassed = $false
            $script:Controls.ValidationStatusText.Text = 'Preview updated. Click Validate Selected to enable single-app creation.'
            $script:Controls.ValidationStatusText.Foreground = '#5F6F7F'
        }
        Update-ActionAvailability
    }
}

function New-ApplicationFolderIfNeeded {
    param([string]$FolderPath)
    if ([string]::IsNullOrWhiteSpace($FolderPath)) { return $null }

    $normalized = (($FolderPath -replace '^Application[\/]*','') -replace '/','\').Trim('\')
    if ([string]::IsNullOrWhiteSpace($normalized)) { return $null }

    $segments = @($normalized -split '\+' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $current = 'Application'
    foreach ($segment in $segments) {
        $next = "$current\$segment"
        $existing = Get-CMFolder -FolderPath $next -ErrorAction SilentlyContinue
        if (-not $existing) {
            New-CMFolder -ParentFolderPath $current -Name $segment -ErrorAction Stop | Out-Null
            Write-WorkbenchLog "Created Application folder $next" 'PASS'
        }
        $current = $next
    }
    return $normalized
}

function Invoke-CreateApplication {
    param([switch]$BatchMode,[object]$BatchItem)
    Update-ProcessingStatus -Stage 'Running final validation...' -StagePercent 8 -Item $BatchItem
    $checks = Test-IntakePlan
    if ($checks.Status -contains 'FAIL') { throw 'Validation failed. Review the Preview tab.' }

    Save-CurrentQueueItemSettings
    $effectiveItem = if ($BatchItem) { $BatchItem } else { $script:State.CurrentQueueItem }
    $appName = Normalize-MetadataText -Value $(if ($effectiveItem) { $effectiveItem.AdministrativeName } else { $script:Controls.AdminNameText.Text })
    $localizedName = Normalize-MetadataText -Value $(if ($effectiveItem) { $effectiveItem.LocalizedName } else { $script:Controls.LocalizedNameText.Text })
    $publisher = Normalize-MetadataText -Value $(if ($effectiveItem) { $effectiveItem.PublisherOverride } else { $script:Controls.PublisherText.Text })
    $version = Normalize-MetadataText -Value $(if ($effectiveItem) { $effectiveItem.VersionOverride } else { $script:Controls.VersionText.Text })
    $description = Normalize-MetadataText -Value $(if ($effectiveItem) { $effectiveItem.Description } else { $script:Controls.DescriptionText.Text })
    $comments = Normalize-MetadataText -Value $(if ($effectiveItem) { $effectiveItem.Comments } else { $script:Controls.CommentsText.Text })
    $installCommand = if ($effectiveItem) { [string]$effectiveItem.InstallCommand } else { $script:Controls.InstallCommandText.Text.Trim() }
    $uninstallCommand = if ($effectiveItem) { [string]$effectiveItem.UninstallCommand } else { $script:Controls.UninstallCommandText.Text.Trim() }
    $iconPath = if ($effectiveItem) { [string](Get-QueueItemValue -Item $effectiveItem -Name 'IconPath' -Default '') } else { '' }
    $detectionType = if ($effectiveItem) { [string]$effectiveItem.DetectionType } else { Get-ComboValue -Combo $script:Controls.DetectionTypeCombo }
    $folder = $script:Controls.FolderCombo.Text.Trim()
    $distributionMode = Get-ComboValue -Combo $script:Controls.DistributionModeCombo
    $distributionTarget = Get-ComboValue -Combo $script:Controls.DistributionTargetCombo
    $collection = if ($effectiveItem) { [string]$effectiveItem.Collection } else { '' }
    $sourceRoot = Get-EffectiveSourceRoot
    if (-not (Test-FileSystemPath -Path $sourceRoot -PathType Container)) {
        if ($script:Controls.AutoCreateSourceCheck.IsChecked) { Ensure-SourceRoot -Path $sourceRoot }
        else { throw "Content source root does not exist: $sourceRoot" }
    }

    Update-ProcessingStatus -Stage 'Preparing standardized source folder...' -StagePercent 18 -Item $BatchItem
    $publisherFolder = ConvertTo-SafeSourcePathComponent -Value $publisher -Fallback 'Unknown Publisher'
    $appFolder = ConvertTo-SafeSourcePathComponent -Value $appName -Fallback 'Unnamed Application'
    $versionFolder = ConvertTo-SafeSourcePathComponent -Value $version -Fallback 'Unknown Version'
    $destination = Join-Path $sourceRoot (Join-Path $publisherFolder (Join-Path $appFolder $versionFolder))
    New-FileSystemDirectory -Path $destination | Out-Null
    $destInstaller = Join-Path $destination ([IO.Path]::GetFileName($script:State.InstallerPath))
    Update-ProcessingStatus -Stage 'Copying installer content...' -StagePercent 25 -Item $BatchItem
    Microsoft.PowerShell.Management\Copy-Item -LiteralPath (Get-FileSystemProviderPath -Path $script:State.InstallerPath) -Destination (Get-FileSystemProviderPath -Path $destInstaller) -Force -ErrorAction Stop
    if (-not (Test-FileSystemPath -Path $destination -PathType Container)) { throw "Standardized source directory was not created: $destination" }
    if (-not (Test-FileSystemPath -Path $destInstaller -PathType Leaf)) { throw "Installer copy verification failed: $destInstaller" }
    $sourceLength = (Microsoft.PowerShell.Management\Get-Item -LiteralPath (Get-FileSystemProviderPath -Path $script:State.InstallerPath) -ErrorAction Stop).Length
    $destinationLength = (Microsoft.PowerShell.Management\Get-Item -LiteralPath (Get-FileSystemProviderPath -Path $destInstaller) -ErrorAction Stop).Length
    if ($sourceLength -ne $destinationLength) { throw "Installer copy size mismatch. Source=$sourceLength bytes; destination=$destinationLength bytes." }
    Write-WorkbenchLog "Copied and verified installer at $destInstaller" 'PASS'

    $script:State.LastCreatedApplicationName = $null
    Update-ProcessingStatus -Stage 'Creating ConfigMgr application...' -StagePercent 38 -Item $BatchItem
    $applicationParams = @{ Name=$appName; Publisher=$publisher; SoftwareVersion=$version; Description=$description; AutoInstall=$true }
    if (-not [string]::IsNullOrWhiteSpace($iconPath) -and (Test-FileSystemPath -Path $iconPath -PathType Leaf)) { $applicationParams.IconLocationFile = $iconPath }
    $application = New-CMApplication @applicationParams
    Set-CMApplication -InputObject $application -ApplyToLanguageById 1033 -LocalizedApplicationName $localizedName -LocalizedDescription $description | Out-Null
    if ($comments) {
        Set-CMApplication -InputObject $application -Description $description -OptionalReference $comments | Out-Null
    }
    $script:State.LastCreatedApplicationName = $appName
    Write-WorkbenchLog "Created application $appName and localized metadata" 'PASS'
    if ($applicationParams.ContainsKey('IconLocationFile')) { Write-WorkbenchLog "Applied Software Center icon from $iconPath" 'PASS' } else { Write-WorkbenchLog "No Software Center icon was applied to $appName" 'WARN' }

    $installerType = if ($effectiveItem) { [string]$effectiveItem.InstallerType } else { [string]$script:State.InstallerType }
    $dtParams = @{
        ApplicationName=$appName; DeploymentTypeName="$appName - $installerType";
        InstallCommand=$installCommand; UninstallCommand=$uninstallCommand;
        InstallationBehaviorType='InstallForSystem'; LogonRequirementType='WhetherOrNotUserLoggedOn';
        UserInteractionMode='Hidden'; MaximumRuntimeMins=15; EstimatedRuntimeMins=2; Force=$true
    }
    if ($installerType -eq 'MSI') { $dtParams.ContentLocation=$destInstaller }
    else { $dtParams.ContentLocation=$destination }
    switch ($detectionType) {
        'MSI product code' {
            if ($installerType -ne 'MSI') { throw 'MSI product-code detection cannot be used for an EXE deployment type.' }
            $dtParams.ProductCode=$script:State.MsiMetadata.ProductCode
        }
        'File exists' { $dtParams.AddDetectionClause=@(New-CMDetectionClauseFile -Path $effectiveItem.DetectionPath.Trim() -FileName $effectiveItem.DetectionFileName.Trim() -Existence) }
        'Registry key/value exists' {
            $hive=[string]$effectiveItem.RegistryHive; $key=[string]$effectiveItem.RegistryKey; $value=[string]$effectiveItem.RegistryValueName
            if ([string]::IsNullOrWhiteSpace($value)) { $clause=New-CMDetectionClauseRegistryKey -Hive $hive -KeyName $key -Existence }
            else { $clause=New-CMDetectionClauseRegistryKeyValue -Hive $hive -KeyName $key -ValueName $value -Existence }
            $dtParams.AddDetectionClause=@($clause)
        }
        'PowerShell script' { $dtParams.ScriptLanguage='PowerShell'; $dtParams.ScriptText=[string]$effectiveItem.DetectionScript }
        default { throw "Unsupported detection type: $detectionType" }
    }
    Update-ProcessingStatus -Stage "Creating $installerType deployment type..." -StagePercent 55 -Item $BatchItem
    if ($installerType -eq 'MSI') { Add-CMMsiDeploymentType @dtParams | Out-Null }
    else {
        # Script deployment types do not expose the MSI UserInteractionMode parameter.
        # Omitting RequireUserInteraction keeps the EXE deployment hidden.
        [void]$dtParams.Remove('UserInteractionMode')
        if ([string]::IsNullOrWhiteSpace($uninstallCommand)) { [void]$dtParams.Remove('UninstallCommand') }
        Add-CMScriptDeploymentType @dtParams | Out-Null
    }
    Write-WorkbenchLog "Created $installerType deployment type for $appName using $detectionType detection" 'PASS'

    Update-ProcessingStatus -Stage 'Applying console folder placement...' -StagePercent 68 -Item $BatchItem
    if ($folder) {
        $normalizedFolder = New-ApplicationFolderIfNeeded -FolderPath $folder
        $destinationFolderPath = "$($script:State.SiteCode):\Application\$normalizedFolder"
        $createdApplication = Get-CMApplication -Name $appName -Fast -ErrorAction Stop
        Move-CMObject -FolderPath $destinationFolderPath -InputObject $createdApplication -ErrorAction Stop | Out-Null
        Write-WorkbenchLog "Moved $appName to $destinationFolderPath" 'PASS'
    }

    Update-ProcessingStatus -Stage 'Requesting content distribution...' -StagePercent 78 -Item $BatchItem
    if ($distributionMode -eq 'Distribution Point') {
        Start-CMContentDistribution -ApplicationName $appName -DistributionPointName $distributionTarget
    }
    else {
        Start-CMContentDistribution -ApplicationName $appName -DistributionPointGroupName $distributionTarget
    }
    Write-WorkbenchLog "Started content distribution to $distributionMode $distributionTarget" 'PASS' 

    Update-ProcessingStatus -Stage 'Applying deployment behavior...' -StagePercent 88 -Item $BatchItem
    if ($effectiveItem -and $effectiveItem.DeploymentAction -eq 'Available') {
        New-CMApplicationDeployment -Name $appName -CollectionName $collection -DeployAction Install -DeployPurpose Available -UserNotification DisplayAll -TimeBaseOn LocalTime | Out-Null
        Write-WorkbenchLog "Created Available deployment to $collection" 'PASS'
    } else {
        Write-WorkbenchLog "Imported $appName without creating a deployment" 'PASS'
    }

    Update-ProcessingStatus -Stage 'Saving intake manifest...' -StagePercent 96 -Item $BatchItem
    $manifest = [ordered]@{
        schemaVersion = 1
        workbenchVersion = $script:AppVersion
        createdAt = (Get-Date).ToString('o')
        siteCode = $script:State.SiteCode
        providerServer = $script:State.ProviderServer
        applicationName = $appName
        localizedName = $localizedName
        publisher = $publisher
        version = $version
        description = $description
        comments = $comments
        installer = [ordered]@{
            originalPath = $script:State.InstallerPath
            sourcePath = $destInstaller
            installerType = $installerType
            installerFramework = if($effectiveItem){$effectiveItem.InstallerFramework}else{$script:State.MsiMetadata.Framework}
            commandConfidence = if($effectiveItem){$effectiveItem.CommandConfidence}else{$script:State.MsiMetadata.CommandConfidence}
            commandsConfirmedByTechnician = if($installerType -eq 'EXE'){[bool]$effectiveItem.ExeCommandsConfirmed}else{$true}
            suggestedApplicationNameSource = if($effectiveItem){Get-QueueItemValue -Item $effectiveItem -Name 'NameSource' -Default ''}else{$script:State.MsiMetadata.NameSource}
            productCode = $script:State.MsiMetadata.ProductCode
            upgradeCode = $script:State.MsiMetadata.UpgradeCode
            sha256 = $script:State.MsiMetadata.Sha256
            signature = $script:State.MsiMetadata.Signature
            signer = $script:State.MsiMetadata.Signer
        }
        icon = [ordered]@{
            mode = if($effectiveItem){Get-QueueItemValue -Item $effectiveItem -Name 'IconMode' -Default 'None'}else{'None'}
            source = if($effectiveItem){Get-QueueItemValue -Item $effectiveItem -Name 'IconSource' -Default 'Unavailable'}else{'Unavailable'}
            quality = if($effectiveItem){Get-QueueItemValue -Item $effectiveItem -Name 'IconQuality' -Default ''}else{''}
            path = if(-not [string]::IsNullOrWhiteSpace($iconPath)){$iconPath}else{$null}
            applied = (-not [string]::IsNullOrWhiteSpace($iconPath) -and (Test-FileSystemPath -Path $iconPath -PathType Leaf))
        }
        deploymentType = [ordered]@{
            installCommand = $installCommand
            uninstallCommand = $uninstallCommand
            detectionType = $detectionType
            detectionPath = if($detectionType -eq 'File exists'){$effectiveItem.DetectionPath}else{$null}
            detectionFileName = if($detectionType -eq 'File exists'){$effectiveItem.DetectionFileName}else{$null}
            registryHive = if($detectionType -eq 'Registry key/value exists'){$effectiveItem.RegistryHive}else{$null}
            registryKey = if($detectionType -eq 'Registry key/value exists'){$effectiveItem.RegistryKey}else{$null}
            registryValueName = if($detectionType -eq 'Registry key/value exists'){$effectiveItem.RegistryValueName}else{$null}
            scriptDetectionConfigured = ($detectionType -eq 'PowerShell script')
            installationBehavior = 'InstallForSystem'
            logonRequirement = 'WhetherOrNotUserLoggedOn'
            userInteraction = 'Hidden'
            maximumRuntimeMinutes = 15
        }
        targets = [ordered]@{
            applicationFolder = $folder
            distributionMode = $distributionMode
            distributionTarget = $distributionTarget
            pilotCollection = if($effectiveItem -and $effectiveItem.DeploymentAction -eq 'Available'){$collection}else{$null}
            deploymentPurpose = if($effectiveItem -and $effectiveItem.DeploymentAction -eq 'Available'){'Available'}else{'None'}
        }
    }
    $manifestPath = Join-Path $script:State.ManifestRoot ((($appName -replace '[^A-Za-z0-9_.-]','_') + '-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.json'))
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Get-FileSystemProviderPath -Path $manifestPath) -Encoding UTF8
    Write-WorkbenchLog "Saved manifest to $manifestPath" 'PASS'
    Update-ProcessingStatus -Stage 'Application intake completed.' -StagePercent 100 -Item $BatchItem

    $script:State.LastCreatedApplicationName = $null
    if (-not $BatchMode) {
        $script:Controls.ResultText.Text = "SUCCESS`r`n`r`nApplication: $appName`r`nSource: $destination`r`nDistribution: $distributionMode - $distributionTarget`r`nManifest: $manifestPath`r`nLog: $script:LogFile"
        $script:Controls.Tabs.SelectedIndex = 4
    }
    return [pscustomobject]@{ ApplicationName=$appName; Source=$destination; Manifest=$manifestPath }
}

$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" xmlns:sys="clr-namespace:System;assembly=mscorlib"
        Title="MECM Application Intake Workbench" Height="900" Width="1220"
        WindowStartupLocation="CenterScreen" MinHeight="720" MinWidth="1000"
        Background="#F3F6F9" FontFamily="Segoe UI" FontSize="13">
    <Window.Resources>
        <SolidColorBrush x:Key="AccentBrush" Color="#2463A8"/>
        <SolidColorBrush x:Key="AccentDarkBrush" Color="#174A80"/>
        <Style TargetType="Button">
            <Setter Property="Background" Value="#2463A8"/><Setter Property="Foreground" Value="White"/>
            <Setter Property="BorderBrush" Value="#174A80"/><Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="16,8"/><Setter Property="Margin" Value="5"/><Setter Property="MinHeight" Value="36"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Style.Triggers><Trigger Property="IsEnabled" Value="False"><Setter Property="Opacity" Value="0.45"/></Trigger></Style.Triggers>
        </Style>
        <Style TargetType="TextBox"><Setter Property="Padding" Value="7,5"/><Setter Property="BorderBrush" Value="#C7D0DA"/></Style>
        <Style TargetType="ComboBox"><Setter Property="Padding" Value="5,4"/><Setter Property="BorderBrush" Value="#C7D0DA"/></Style>
        <Style TargetType="TabItem"><Setter Property="Padding" Value="18,8"/><Setter Property="FontWeight" Value="SemiBold"/></Style>
        <Style TargetType="DataGrid"><Setter Property="GridLinesVisibility" Value="Horizontal"/><Setter Property="AlternatingRowBackground" Value="#F7F9FB"/><Setter Property="HeadersVisibility" Value="Column"/><Setter Property="BorderBrush" Value="#D5DDE5"/></Style>
        <Style x:Key="Card" TargetType="Border"><Setter Property="Background" Value="White"/><Setter Property="BorderBrush" Value="#D8E0E8"/><Setter Property="BorderThickness" Value="1"/><Setter Property="CornerRadius" Value="7"/><Setter Property="Padding" Value="14"/></Style>
    </Window.Resources>
    <Grid>
        <Grid.RowDefinitions><RowDefinition Height="82"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
        <Border Grid.Row="0" Background="#173A5E" Padding="22,14">
            <Grid><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <StackPanel><TextBlock Text="MECM Application Intake Workbench" Foreground="White" FontSize="23" FontWeight="SemiBold"/>
                    <TextBlock Text="Guarded MSI and EXE intake with icon handling, distribution, and pilot deployment" Foreground="#C9D9E8" Margin="0,4,0,0"/></StackPanel>
                <Border Grid.Column="1" x:Name="ConnectionStatusBorder" Background="#B36B00" CornerRadius="5" Padding="14,8" VerticalAlignment="Center">
                    <StackPanel>
                        <StackPanel Orientation="Horizontal" HorizontalAlignment="Center">
                            <TextBlock x:Name="ConnectionIcon" Text="&#x25B2;" Foreground="White" FontWeight="Bold" FontSize="15" Margin="0,0,8,0"/>
                            <TextBlock x:Name="ConnectionStatus" Text="Not Connected" Foreground="White" FontWeight="SemiBold"/>
                        </StackPanel>
                        <ProgressBar x:Name="ConnectionActivity" Height="3" Margin="0,6,0,0" IsIndeterminate="True" Visibility="Collapsed"/>
                    </StackPanel>
                </Border>
            </Grid>
        </Border>
        <Grid Grid.Row="1" Margin="18,14"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <Border Grid.Row="0" Style="{StaticResource Card}" Margin="0,0,0,12" BorderBrush="#2463A8" BorderThickness="2"><Grid>
                <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="80"/><ColumnDefinition Width="24"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="250"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                <TextBlock Grid.Row="0" Grid.Column="0" Text="Site" VerticalAlignment="Center" FontWeight="SemiBold"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="SiteCodeText" Text="ABC" Margin="8,0"/>
                <TextBlock Grid.Row="0" Grid.Column="3" Text="Provider" VerticalAlignment="Center" FontWeight="SemiBold"/><TextBox Grid.Row="0" Grid.Column="4" x:Name="ProviderText" Text="CM01.contoso.com" Margin="8,0"/>
                <Button Grid.Row="0" Grid.Column="6" x:Name="ConnectButton" Content="1. Connect to MECM" FontWeight="Bold" MinWidth="190" Padding="20,10"/>
                <TextBlock Grid.Row="1" Grid.Column="0" Grid.ColumnSpan="7" x:Name="ConnectionInstruction" Text="First step: enter the site and provider, then connect before adding or processing applications." Foreground="#174A80" FontWeight="SemiBold" Margin="0,10,0,0" TextWrapping="Wrap"/>
            </Grid></Border>
            <TabControl Grid.Row="1" x:Name="Tabs" Background="White">
                <TabItem Header="1. Intake &amp; Queue"><Grid Margin="14"><Grid.RowDefinitions><RowDefinition Height="210"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <Border Grid.Row="0" Style="{StaticResource Card}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <DockPanel Grid.Row="0" Margin="0,0,0,8"><StackPanel Orientation="Horizontal" DockPanel.Dock="Left"><Button x:Name="AddBatchButton" Content="Add installer files"/><Button x:Name="RemoveBatchButton" Content="Remove selected" Background="#5E6B78"/><Button x:Name="ClearBatchButton" Content="Clear queue" Background="#5E6B78"/></StackPanel><TextBlock x:Name="BatchCountText" Text="0 package(s) queued" HorizontalAlignment="Right" VerticalAlignment="Center" Foreground="#566574"/></DockPanel>
                        <DataGrid Grid.Row="1" x:Name="BatchGrid" AutoGenerateColumns="False" IsReadOnly="False" SelectionMode="Extended" SelectionUnit="FullRow"><DataGrid.Columns>
                            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="85" IsReadOnly="True"/><DataGridTextColumn Header="Application" Binding="{Binding Application}" Width="2*" IsReadOnly="True"/><DataGridTextColumn Header="Version" Binding="{Binding Version}" Width="100" IsReadOnly="True"/><DataGridTemplateColumn Header="Deployment behavior" Width="155"><DataGridTemplateColumn.CellTemplate><DataTemplate><ComboBox SelectedItem="{Binding DeploymentAction, UpdateSourceTrigger=PropertyChanged}" Margin="3" Padding="5,2"><sys:String>Import only</sys:String><sys:String>Available</sys:String></ComboBox></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn><DataGridTemplateColumn Header="Collection" Width="200"><DataGridTemplateColumn.CellTemplate><DataTemplate><ComboBox ItemsSource="{Binding CollectionChoices}" SelectedItem="{Binding Collection, UpdateSourceTrigger=PropertyChanged}" Margin="3" Padding="5,2"><ComboBox.Style><Style TargetType="ComboBox" BasedOn="{StaticResource {x:Type ComboBox}}"><Style.Triggers><DataTrigger Binding="{Binding DeploymentAction}" Value="Import only"><Setter Property="IsEnabled" Value="False"/><Setter Property="ToolTip" Value="Not applicable for Import only"/></DataTrigger></Style.Triggers></Style></ComboBox.Style></ComboBox></DataTemplate></DataGridTemplateColumn.CellTemplate></DataGridTemplateColumn><DataGridTextColumn Header="Publisher" Binding="{Binding Publisher}" Width="150" IsReadOnly="True"/><DataGridTextColumn Header="File" Binding="{Binding File}" Width="2*" IsReadOnly="True"/><DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="2*" IsReadOnly="True"/>
                        </DataGrid.Columns></DataGrid>
                    </Grid></Border>
                    <TextBlock Grid.Row="1" Text="Add and configure all intended applications. When the queue and application details are complete, continue to the Deployment Type tab." Foreground="#405466" FontWeight="SemiBold" TextWrapping="Wrap" Margin="4,9,4,9"/>
                    <Grid Grid.Row="2"><Grid.ColumnDefinitions><ColumnDefinition Width="3*" MinWidth="650"/><ColumnDefinition Width="12"/><ColumnDefinition Width="1*" MinWidth="240"/></Grid.ColumnDefinitions>
                        <Border Grid.Column="0" Style="{StaticResource Card}"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><Grid Margin="0,0,4,0">
                            <Grid.ColumnDefinitions><ColumnDefinition Width="180"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Text="Selected installer" Margin="0,7"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="InstallerText" IsReadOnly="True" Margin="8,3"/><Button Grid.Row="0" Grid.Column="2" x:Name="BrowseButton" Content="Browse"/>
                            <TextBlock Grid.Row="1" Text="Administrative name" Margin="0,7"/><TextBox Grid.Row="1" Grid.Column="1" Grid.ColumnSpan="2" x:Name="AdminNameText" Margin="8,3"/>
                            <TextBlock Grid.Row="2" Text="Software Center name" Margin="0,7"/><TextBox Grid.Row="2" Grid.Column="1" Grid.ColumnSpan="2" x:Name="LocalizedNameText" Margin="8,3"/>
                            <TextBlock Grid.Row="3" Text="Publisher" Margin="0,7"/><TextBox Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2" x:Name="PublisherText" Margin="8,3"/>
                            <TextBlock Grid.Row="4" Text="Version" Margin="0,7"/><TextBox Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2" x:Name="VersionText" Margin="8,3"/>
                            <TextBlock Grid.Row="5" Text="Product code / EXE profile" Margin="0,7"/><TextBox Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2" x:Name="ProductCodeText" Margin="8,3" IsReadOnly="True"/>
                            <TextBlock Grid.Row="6" Text="SHA-256" Margin="0,7"/><TextBox Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="2" x:Name="HashText" Margin="8,3" IsReadOnly="True"/>
                            <TextBlock Grid.Row="7" Text="Signature" Margin="0,7"/><TextBox Grid.Row="7" Grid.Column="1" Grid.ColumnSpan="2" x:Name="SignatureText" Margin="8,3" IsReadOnly="True"/>
                            <TextBlock Grid.Row="8" Text="Description" Margin="0,7"/><TextBox Grid.Row="8" Grid.Column="1" Grid.ColumnSpan="2" x:Name="DescriptionText" Height="70" AcceptsReturn="True" TextWrapping="Wrap" Margin="8,3"/>
                            <TextBlock Grid.Row="9" Text="Administrative comments" Margin="0,7"/><TextBox Grid.Row="9" Grid.Column="1" Grid.ColumnSpan="2" x:Name="CommentsText" Height="55" AcceptsReturn="True" TextWrapping="Wrap" Margin="8,3"/>
                        </Grid></ScrollViewer></Border>
                        <Border Grid.Column="2" Style="{StaticResource Card}"><Grid>
                            <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions>
                            <TextBlock Grid.Row="0" Text="Application Icon" FontWeight="SemiBold" FontSize="15"/>
                            <TextBlock Grid.Row="1" Text="Optional: review the extracted icon or choose a replacement." Foreground="#5F6F7F" TextWrapping="Wrap" Margin="0,2,0,6"/>
                            <Grid Grid.Row="2" MinHeight="82"><Grid.ColumnDefinitions><ColumnDefinition Width="88"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <Border Width="80" Height="80" Background="White" BorderBrush="#C7D0DA" BorderThickness="1" HorizontalAlignment="Left" VerticalAlignment="Top"><Image x:Name="IconPreview" Stretch="Uniform" StretchDirection="DownOnly" RenderOptions.BitmapScalingMode="HighQuality" Margin="5"/></Border>
                                <TextBlock Grid.Column="1" x:Name="IconStatusText" Text="No application selected." Foreground="#405466" TextWrapping="Wrap" Margin="7,0,0,0" VerticalAlignment="Top" FontSize="11"/>
                            </Grid>
                            <Grid Grid.Row="3" Margin="0,6,0,0"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                                <Button Grid.Column="0" x:Name="UseExtractedIconButton" Content="Extracted" Padding="5,4" MinHeight="28" Margin="0,0,3,0"/>
                                <Button Grid.Column="1" x:Name="ChooseIconButton" Content="Replace..." Padding="5,4" MinHeight="28" Margin="3,0"/>
                                <Button Grid.Column="2" x:Name="NoIconButton" Content="No icon" Background="#5E6B78" Padding="5,4" MinHeight="28" Margin="3,0,0,0"/>
                            </Grid>
                        </Grid></Border>
                    </Grid>
                </Grid></TabItem>
                <TabItem Header="2. Deployment Type"><Grid Margin="14"><Grid.ColumnDefinitions><ColumnDefinition Width="310"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Border Grid.Column="0" Style="{StaticResource Card}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><StackPanel Margin="0,0,0,8"><TextBlock Text="Queued applications" FontWeight="SemiBold" FontSize="15"/><TextBlock x:Name="DeploymentTypePositionText" Text="No application selected" Foreground="#5F6F7F" Margin="0,3,0,0"/></StackPanel><DataGrid Grid.Row="1" x:Name="DeploymentTypeQueueGrid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" SelectionUnit="FullRow"><DataGrid.Columns><DataGridTextColumn Header="Application" Binding="{Binding Application}" Width="*"/><DataGridTextColumn Header="Config" Binding="{Binding ValidationState}" Width="110"/></DataGrid.Columns></DataGrid><StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,10,0,0"><Button x:Name="PreviousAppButton" Content="Previous" Background="#5E6B78"/><Button x:Name="NextAppButton" Content="Next" Background="#5E6B78"/></StackPanel></Grid></Border>
<Grid Grid.Column="2"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
<Border Grid.Column="0" Style="{StaticResource Card}"><ScrollViewer VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"><StackPanel Margin="0,0,4,0"><TextBlock Text="Command lines" FontWeight="SemiBold" FontSize="15"/>
<TextBlock Text="Install command" Margin="0,10,0,3"/><TextBox x:Name="InstallCommandText" FontFamily="Consolas" AcceptsReturn="True" TextWrapping="Wrap" MinHeight="75"/>
<TextBlock Text="Uninstall command" Margin="0,10,0,3"/><TextBox x:Name="UninstallCommandText" FontFamily="Consolas" AcceptsReturn="True" TextWrapping="Wrap" MinHeight="75"/>
<Button x:Name="ResetCommandsButton" Content="Reset suggested commands" HorizontalAlignment="Right" Margin="0,10,0,0"/>
<TextBlock Text="Commands are stored per queued application. MSI defaults are verified from package metadata. EXE commands are best-effort suggestions and require technician approval." Foreground="#5F6F7F" TextWrapping="Wrap" Margin="0,12,0,0"/><TextBlock x:Name="InstallerProfileText" Text="Installer profile" Foreground="#405466" TextWrapping="Wrap" Margin="0,10,0,0"/><Border x:Name="CommandApprovalPanel" Visibility="Collapsed" Background="#FFF5DA" BorderBrush="#E7C66B" BorderThickness="2" CornerRadius="6" Padding="12" Margin="0,12,0,0"><StackPanel><TextBlock x:Name="CommandApprovalHeading" Text="Technician Approval Required" FontWeight="Bold" FontSize="14" Foreground="#664B00"/><TextBlock Text="Review the final EXE commands, then check this box to allow validation and creation. Editing either command clears approval." Foreground="#664B00" TextWrapping="Wrap" Margin="0,4,0,8"/><CheckBox x:Name="CommandApprovalCheck" Content="I reviewed and approve the EXE install command and any uninstall command entered" FontWeight="SemiBold"/></StackPanel></Border><TextBlock x:Name="ExeValidationRequirementText" Text="EXE readiness will appear here after an EXE is selected." Foreground="#A66722" TextWrapping="Wrap" Margin="0,6,0,0" Visibility="Collapsed"/>
<TextBlock Text="Review and adjust the deployment settings for each intended application. When all additions or changes are complete, continue to the MECM Target tab." Foreground="#405466" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,14,0,0"/></StackPanel></ScrollViewer></Border>
<Border Grid.Column="2" Style="{StaticResource Card}"><ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel><TextBlock Text="Detection method" FontWeight="SemiBold" FontSize="15"/>
<ComboBox x:Name="DetectionTypeCombo" Margin="0,8,0,12"><ComboBoxItem Content="MSI product code"/><ComboBoxItem Content="File exists"/><ComboBoxItem Content="Registry key/value exists"/><ComboBoxItem Content="PowerShell script"/></ComboBox>
<StackPanel x:Name="MsiDetectionPanel"><TextBlock Text="Uses the MSI product code extracted from an MSI package. This method is unavailable for EXE packages." TextWrapping="Wrap"/></StackPanel>
<StackPanel x:Name="FileDetectionPanel" Visibility="Collapsed"><TextBlock Text="Folder path"/><TextBox x:Name="DetectionPathText" Margin="0,3,0,8"/><TextBlock Text="File name"/><TextBox x:Name="DetectionFileNameText" Margin="0,3,0,0"/></StackPanel>
<StackPanel x:Name="RegistryDetectionPanel" Visibility="Collapsed"><TextBlock Text="Hive"/><ComboBox x:Name="RegistryHiveCombo" Margin="0,3,0,8"><ComboBoxItem Content="LocalMachine"/><ComboBoxItem Content="CurrentUser"/><ComboBoxItem Content="ClassesRoot"/><ComboBoxItem Content="Users"/><ComboBoxItem Content="CurrentConfig"/></ComboBox><TextBlock Text="Key path"/><TextBox x:Name="RegistryKeyText" Margin="0,3,0,8"/><TextBlock Text="Value name (optional)"/><TextBox x:Name="RegistryValueNameText" Margin="0,3,0,0"/></StackPanel>
<StackPanel x:Name="ScriptDetectionPanel" Visibility="Collapsed"><TextBlock Text="PowerShell detection script"/><TextBox x:Name="DetectionScriptText" FontFamily="Consolas" AcceptsReturn="True" TextWrapping="NoWrap" MinHeight="220" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/><TextBlock Text="Syntax checked only; never executed by the workbench." Foreground="#5F6F7F" Margin="0,5,0,0"/></StackPanel>
</StackPanel></ScrollViewer></Border></Grid></Grid></TabItem>
<TabItem Header="3. MECM Target"><Border Style="{StaticResource Card}" Margin="14"><Grid>
                    <Grid.ColumnDefinitions><ColumnDefinition Width="210"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions>
                    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Grid.Row="0" Text="Content source root" Margin="0,9"/><TextBox Grid.Row="0" Grid.Column="1" x:Name="SourceRootText" Text="\\CM01\MECMSources$\Applications" Margin="8,4"/><Button Grid.Row="0" Grid.Column="2" x:Name="BrowseSourceButton" Content="Browse"/>
                    <CheckBox Grid.Row="1" Grid.Column="1" x:Name="AutoCreateSourceCheck" Content="Create source root when its parent is reachable" IsChecked="True" Margin="8,7"/><Button Grid.Row="1" Grid.Column="2" x:Name="CreateSourceButton" Content="Create now"/>
                    <TextBlock Grid.Row="2" Text="Application folder" Margin="0,9"/><ComboBox Grid.Row="2" Grid.Column="1" x:Name="FolderCombo" IsEditable="True" IsTextSearchEnabled="True" Margin="8,4"/><Button Grid.Row="2" Grid.Column="2" x:Name="CreateAppFolderButton" Content="Create folder"/>
                    <TextBlock Grid.Row="3" Text="Distribution target type" Margin="0,9"/><ComboBox Grid.Row="3" Grid.Column="1" Grid.ColumnSpan="2" x:Name="DistributionModeCombo" Margin="8,4"><ComboBoxItem Content="DP Group"/><ComboBoxItem Content="Distribution Point"/></ComboBox>
                    <TextBlock Grid.Row="4" Text="Distribution target" Margin="0,9"/><ComboBox Grid.Row="4" Grid.Column="1" Grid.ColumnSpan="2" x:Name="DistributionTargetCombo" Margin="8,4"/>
                    <TextBlock Grid.Row="5" Text="Per-app deployment" Margin="0,9"/><TextBlock Grid.Row="5" Grid.Column="1" Grid.ColumnSpan="2" Text="Set directly in the intake queue." Foreground="#5F6F7F" Margin="8,9"/>
                    <TextBlock Grid.Row="6" Text="Collection targeting" Margin="0,9"/><TextBlock Grid.Row="6" Grid.Column="1" Grid.ColumnSpan="2" Text="Set per application in the queue." Foreground="#5F6F7F" Margin="8,9"/>
                    <TextBlock Grid.Row="7" Grid.ColumnSpan="3" Text="Confirm the MECM source, folder, distribution, deployment, and collection settings. When all intended additions or changes are complete, continue to the Review &amp; Validate tab." Foreground="#405466" FontWeight="SemiBold" TextWrapping="Wrap" Margin="0,12,0,0"/>
                    <Border Grid.Row="8" Grid.ColumnSpan="3" Background="#FFF5DA" BorderBrush="#E7C66B" BorderThickness="1" CornerRadius="5" Padding="12" Margin="0,18,0,0"><TextBlock Text="Guardrail: Import only is the default. It stages the application and distributes content without exposing it in Software Center. Available deployment must be selected deliberately and remains device-targeted to the chosen collection." Foreground="#664B00" TextWrapping="Wrap"/></Border>
                </Grid></Border></TabItem>
                <TabItem Header="4. Review &amp; Validate"><Grid Margin="14"><Grid.ColumnDefinitions><ColumnDefinition Width="470"/><ColumnDefinition Width="12"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
                    <Border Grid.Column="0" Style="{StaticResource Card}"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <StackPanel Margin="0,0,0,8"><TextBlock Text="Intake queue" FontWeight="SemiBold" FontSize="15"/><TextBlock Text="Select packages here without returning to the Intake tab." Foreground="#5F6F7F" TextWrapping="Wrap" Margin="0,3,0,0"/></StackPanel>
                        <DataGrid Grid.Row="1" x:Name="ReviewQueueGrid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single" SelectionUnit="FullRow"><DataGrid.Columns>
                            <DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="72"/><DataGridTextColumn Header="Application" Binding="{Binding Application}" Width="*"/><DataGridTextColumn Header="Deploy" Binding="{Binding DeploymentAction}" Width="115"/><DataGridTextColumn Header="Collection" Binding="{Binding Collection}" Width="155"/>
                        </DataGrid.Columns></DataGrid>
                    </Grid></Border>
                    <Grid Grid.Column="2"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/><RowDefinition Height="250"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                        <StackPanel Grid.Row="0" Margin="0,0,0,8"><TextBlock x:Name="SelectedPreviewText" Text="Selected package: none" FontWeight="SemiBold" FontSize="15" TextTrimming="CharacterEllipsis"/><TextBlock Text="Pre-Commit Review is the final read-only summary of choices made in Intake &amp; Queue, Deployment Type, and MECM Target. Make any changes on those tabs. Use Validate Selected before Create Selected Application for one item, or Validate All before Process Queue for the batch. Validation performs readiness checks only; it does not create or modify MECM objects. Processing revalidates each application immediately before commit." Foreground="#405466" TextWrapping="Wrap" Margin="0,3,0,0"/></StackPanel>
                        <StackPanel Grid.Row="1" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,0,0,8"><Button x:Name="ValidateAllButton" Content="Validate All" Background="#5E6B78" MinWidth="145"/><Button x:Name="ValidateButton" Content="Validate Selected" Margin="8,0,0,0" MinWidth="145"/></StackPanel>
                        <TextBlock Grid.Row="2" x:Name="ValidationStatusText" Text="Select a package, then validate it." Foreground="#5F6F7F" Margin="0,0,0,8" TextWrapping="Wrap"/>
                        <DataGrid Grid.Row="3" x:Name="ValidationGrid" AutoGenerateColumns="False" IsReadOnly="True"><DataGrid.Columns><DataGridTextColumn Header="Check" Binding="{Binding Check}" Width="2*"/><DataGridTextColumn Header="Status" Binding="{Binding Status}" Width="90"/><DataGridTextColumn Header="Detail" Binding="{Binding Detail}" Width="3*"/></DataGrid.Columns></DataGrid>
                        <TextBlock Grid.Row="4" Text="Planned operations" FontWeight="SemiBold" Margin="0,14,0,6"/><TextBox Grid.Row="5" x:Name="PlanText" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" VerticalScrollBarVisibility="Auto"/>
                    </Grid>
                </Grid></TabItem>
                <TabItem Header="5. Results &amp; Log"><Grid Margin="14"><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="170"/><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
                    <TextBlock Text="Result" FontWeight="SemiBold"/><TextBox Grid.Row="1" x:Name="ResultText" IsReadOnly="True" AcceptsReturn="True" TextWrapping="Wrap" Margin="0,6,0,0"/>
                    <TextBlock Grid.Row="2" Text="Transaction log" FontWeight="SemiBold" Margin="0,14,0,6"/><TextBox Grid.Row="3" x:Name="LogBox" IsReadOnly="True" AcceptsReturn="True" TextWrapping="NoWrap" FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Auto"/>
                </Grid></TabItem>
            </TabControl>
        </Grid>
        <Border Grid.Row="2" Background="White" BorderBrush="#D8E0E8" BorderThickness="0,1,0,0" Padding="18,10"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
            <DockPanel Grid.Row="0"><TextBlock x:Name="VersionTextBlock" VerticalAlignment="Center" Foreground="#5F6F7F"/><StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center" DockPanel.Dock="Right"><Button x:Name="CancelBatchButton" Content="Cancel after current application" Visibility="Collapsed" Background="#A66722" MinWidth="210"/><Button x:Name="ProcessBatchButton" Content="Process Queue" IsEnabled="False" Background="#2F7D4A" MinWidth="145"/><Button x:Name="CreateButton" Content="Create Selected Application" IsEnabled="False" MinWidth="205"/></StackPanel></DockPanel>
            <Border Grid.Row="1" x:Name="ProgressPanel" Visibility="Collapsed" Background="#EAF2FA" BorderBrush="#8FB3D9" BorderThickness="1" CornerRadius="6" Padding="12" Margin="0,9,0,0"><Grid><Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="Auto"/></Grid.RowDefinitions><Grid.ColumnDefinitions><ColumnDefinition Width="2*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><StackPanel><TextBlock x:Name="ProgressTitleText" FontWeight="SemiBold" FontSize="16"/><TextBlock x:Name="ProgressStageText" Foreground="#40556A" Margin="0,3,0,6" TextWrapping="Wrap"/><ProgressBar x:Name="StageProgressBar" Height="12" Minimum="0" Maximum="100" IsIndeterminate="True"/></StackPanel><StackPanel Grid.Column="1" Margin="22,0,0,0"><TextBlock Text="Overall queue progress" FontWeight="SemiBold"/><TextBlock x:Name="OverallProgressText" Foreground="#40556A" Margin="0,3,0,6"/><ProgressBar x:Name="OverallProgressBar" Height="12" Minimum="0" Maximum="1"/></StackPanel><TextBlock Grid.Row="1" Grid.ColumnSpan="2" x:Name="QueueStatusText" Text="Queue status: no active processing" Foreground="#40556A" Margin="0,9,0,0" FontFamily="Consolas"/></Grid></Border>
        </Grid></Border>
    </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader ([xml]$xaml)
$window = [Windows.Markup.XamlReader]::Load($reader)

$names = @('ConnectionStatusBorder','ConnectionIcon','ConnectionStatus','ConnectionActivity','SiteCodeText','ProviderText','ConnectButton','ConnectionInstruction','Tabs','AddBatchButton','RemoveBatchButton','ClearBatchButton','BatchCountText','BatchGrid','InstallerText','BrowseButton','AdminNameText','LocalizedNameText','PublisherText','VersionText','ProductCodeText','HashText','SignatureText','IconPreview','IconStatusText','UseExtractedIconButton','ChooseIconButton','NoIconButton','DescriptionText','CommentsText','DeploymentTypePositionText','DeploymentTypeQueueGrid','PreviousAppButton','NextAppButton','InstallCommandText','UninstallCommandText','ResetCommandsButton','InstallerProfileText','CommandApprovalPanel','CommandApprovalHeading','CommandApprovalCheck','ExeValidationRequirementText','DetectionTypeCombo','MsiDetectionPanel','FileDetectionPanel','DetectionPathText','DetectionFileNameText','RegistryDetectionPanel','RegistryHiveCombo','RegistryKeyText','RegistryValueNameText','ScriptDetectionPanel','DetectionScriptText','SourceRootText','BrowseSourceButton','AutoCreateSourceCheck','CreateSourceButton','FolderCombo','CreateAppFolderButton','DistributionModeCombo','DistributionTargetCombo','ReviewQueueGrid','SelectedPreviewText','ValidateAllButton','ValidateButton','ValidationStatusText','ValidationGrid','PlanText','ResultText','LogBox','VersionTextBlock','CancelBatchButton','ProcessBatchButton','CreateButton','ProgressPanel','ProgressTitleText','ProgressStageText','StageProgressBar','OverallProgressText','OverallProgressBar','QueueStatusText')
$script:Controls = @{}
foreach ($name in $names) { $script:Controls[$name] = $window.FindName($name) }
$script:Controls.DistributionModeCombo.SelectedIndex = 0
$script:Controls.DetectionTypeCombo.SelectedIndex = 0
$script:Controls.RegistryHiveCombo.SelectedIndex = 0
$script:Controls.SourceRootText.Text = $script:State.SourceRoot
$window.Title = "MECM Application Intake Workbench v$script:AppVersion"
$script:Controls.VersionTextBlock.Text = "v$script:AppVersion | Technician-configurable MSI and EXE intake with icon handling"

function Save-CurrentQueueItemSettings {
    $item = $script:State.CurrentQueueItem
    if (-not $item -or $script:State.PreviewBusy) { return }
    $item.AdministrativeName = Normalize-MetadataText -Value $script:Controls.AdminNameText.Text
    $item.LocalizedName = Normalize-MetadataText -Value $script:Controls.LocalizedNameText.Text
    $item.PublisherOverride = Normalize-MetadataText -Value $script:Controls.PublisherText.Text
    $item.VersionOverride = Normalize-MetadataText -Value $script:Controls.VersionText.Text
    $item.Description = $script:Controls.DescriptionText.Text
    $item.Comments = $script:Controls.CommentsText.Text
    $item.Application = $item.AdministrativeName
    $item.Version = $item.VersionOverride
    $item.Publisher = $item.PublisherOverride
    Save-SelectedDeploymentTypeSettings

    # Preserve validation when selection merely causes the current values to be
    # written back unchanged. Revoke it only when the validated configuration
    # fingerprint differs from the item's current configuration.
    if ($item.ValidationState -eq 'Validated') {
        $currentFingerprint = Get-QueueItemValidationFingerprint -Item $item
        if ([string]::IsNullOrWhiteSpace([string]$item.ValidationFingerprint) -or
            $item.ValidationFingerprint -ne $currentFingerprint) {
            $item.ValidationState = 'Modified - revalidate'
            $item.ValidationTimestamp = $null
            $item.ValidationFingerprint = $null
            if ($script:State.CurrentQueueItem -eq $item) {
                $script:State.LastValidatedPath = $null
                $script:State.LastValidationPassed = $false
            }
        }
    }
}

function Select-QueueItem {
    param([object]$Item,[System.Windows.Controls.DataGrid]$OriginGrid)
    if (-not $Item -or -not $Item.Path -or $Item.Status -eq 'Blocked') { return }
    if ($script:State.PreviewBusy -or $script:State.SelectionSyncBusy) { return }
    $script:State.SelectionSyncBusy = $true
    try {
        Save-CurrentQueueItemSettings
        Initialize-QueueItemExeProperties -Item $Item
        $script:State.CurrentQueueItem = $Item
        if ($OriginGrid -ne $script:Controls.BatchGrid) { $script:Controls.BatchGrid.SelectedItem = $Item }
        if ($OriginGrid -ne $script:Controls.ReviewQueueGrid) { $script:Controls.ReviewQueueGrid.SelectedItem = $Item }
        if ($OriginGrid -ne $script:Controls.DeploymentTypeQueueGrid) { $script:Controls.DeploymentTypeQueueGrid.SelectedItem = $Item }
        Set-CurrentInstaller -Path $Item.Path -Metadata $Item.Metadata -SuppressMetadataLog
        $script:State.PreviewBusy = $true
        try {
            $script:Controls.AdminNameText.Text = [string]$Item.AdministrativeName
            $script:Controls.LocalizedNameText.Text = [string]$Item.LocalizedName
            $script:Controls.PublisherText.Text = [string]$Item.PublisherOverride
            $script:Controls.VersionText.Text = [string]$Item.VersionOverride
            $script:Controls.DescriptionText.Text = [string]$Item.Description
            $script:Controls.CommentsText.Text = [string]$Item.Comments
            Load-DeploymentTypeSettings -Item $Item
            Update-IconPreview -Item $Item
            $index = [array]::IndexOf(@($script:State.BatchItems),$Item) + 1
            $script:Controls.DeploymentTypePositionText.Text = "Application $index of $($script:State.BatchItems.Count) - $($Item.Application)"
        } finally { $script:State.PreviewBusy = $false }
    }
    finally { $script:State.SelectionSyncBusy = $false }
    Update-Preview
}

$script:Controls.UseExtractedIconButton.Add_Click({
    try {
        $item = $script:State.CurrentQueueItem
        if (-not $item) { return }
        $path = [string](Get-QueueItemValue -Item $item -Name 'ExtractedIconPath' -Default '')
        if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-FileSystemPath -Path $path -PathType Leaf)) { throw 'No extracted icon is available for this installer.' }
        $dimensions = Get-ImageDimensions -Path $path
        $item.IconMode='Extracted'; $item.IconPath=$path
        $item.IconSource = if ([string]$item.InstallerType -eq 'EXE') { 'Extracted from installer executable' } else { 'Extracted shell icon from MSI; may be generic' }
        $item.IconQuality = if ($dimensions.Width -lt 64 -or $dimensions.Height -lt 64) { 'Low resolution' } else { 'Candidate' }
        $item.IconWidth=$dimensions.Width; $item.IconHeight=$dimensions.Height
        Update-IconPreview -Item $item
        Save-CurrentQueueItemSettings
        Write-WorkbenchLog "Selected extracted icon for $($item.Application): $path" 'INFO'
    } catch { Write-WorkbenchLog "Unable to use extracted icon: $($_.Exception.Message)" 'WARN'; Show-ErrorDialog 'Icon selection failed' $_.Exception.Message }
})
$script:Controls.ChooseIconButton.Add_Click({
    try {
        $item = $script:State.CurrentQueueItem
        if (-not $item) { throw 'Select an application first.' }
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Supported icon images (*.png;*.jpg;*.jpeg;*.ico)|*.png;*.jpg;*.jpeg;*.ico|PNG image (*.png)|*.png|JPEG image (*.jpg;*.jpeg)|*.jpg;*.jpeg|Icon file (*.ico)|*.ico'
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $dimensions = Get-ImageDimensions -Path $dialog.FileName
            $item.IconMode='User supplied'; $item.IconPath=$dialog.FileName; $item.IconSource='User supplied replacement'
            $item.IconQuality = if ($dimensions.Width -lt 64 -or $dimensions.Height -lt 64) { 'Low resolution' } else { 'Technician selected' }
            $item.IconWidth=$dimensions.Width; $item.IconHeight=$dimensions.Height
            Update-IconPreview -Item $item
            Save-CurrentQueueItemSettings
            Write-WorkbenchLog "Selected replacement icon for $($item.Application): $($dialog.FileName)" 'INFO'
        }
    } catch { Write-WorkbenchLog "Unable to select replacement icon: $($_.Exception.Message)" 'WARN'; Show-ErrorDialog 'Icon selection failed' $_.Exception.Message }
})
$script:Controls.NoIconButton.Add_Click({
    $item = $script:State.CurrentQueueItem
    if (-not $item) { return }
    $item.IconMode='None'; $item.IconPath=''; $item.IconSource='Technician selected no icon'; $item.IconQuality='Not applicable'; $item.IconWidth=0; $item.IconHeight=0
    Update-IconPreview -Item $item
    Save-CurrentQueueItemSettings
    Write-WorkbenchLog "No icon selected for $($item.Application)" 'INFO'
})

$script:Controls.BrowseButton.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Supported installers (*.msi;*.exe)|*.msi;*.exe|Windows Installer (*.msi)|*.msi|Executable installer (*.exe)|*.exe'
        $dialog.Multiselect = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            foreach ($file in $dialog.FileNames) { Add-InstallerToBatch -Path $file }
            $first = @($script:State.BatchItems | Where-Object Path -eq $dialog.FileNames[0] | Select-Object -First 1)[0]
            if ($first) { Select-QueueItem -Item $first -OriginGrid $null }
        }
    } catch {
        Write-WorkbenchLog $_.Exception.Message 'ERROR'
        Show-ErrorDialog 'Installer inspection failed' $_.Exception.Message
    }
})

$script:Controls.AddBatchButton.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = 'Supported installers (*.msi;*.exe)|*.msi;*.exe|Windows Installer (*.msi)|*.msi|Executable installer (*.exe)|*.exe'; $dialog.Multiselect = $true
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            foreach ($file in $dialog.FileNames) { Add-InstallerToBatch -Path $file }
            if ($dialog.FileNames.Count -gt 0) { $first=@($script:State.BatchItems | Where-Object Path -eq $dialog.FileNames[0] | Select-Object -First 1)[0]; if($first){Select-QueueItem -Item $first -OriginGrid $null} }
        }
    } catch { Write-WorkbenchLog $_.Exception.Message 'ERROR'; Show-ErrorDialog 'Unable to add installer files' $_.Exception.Message }
})

$script:Controls.RemoveBatchButton.Add_Click({
    foreach ($selected in @($script:Controls.BatchGrid.SelectedItems)) { [void]$script:State.BatchItems.Remove($selected) }
    Refresh-BatchGrid
})
$script:Controls.ClearBatchButton.Add_Click({ $script:State.BatchItems.Clear(); Refresh-BatchGrid })
$script:Controls.BatchGrid.Add_SelectionChanged({
    try { Select-QueueItem -Item $script:Controls.BatchGrid.SelectedItem -OriginGrid $script:Controls.BatchGrid }
    catch { Write-WorkbenchLog "Queue selection preview failed: $($_.Exception.Message)" 'WARN' }
})
$script:Controls.ReviewQueueGrid.Add_SelectionChanged({
    try { Select-QueueItem -Item $script:Controls.ReviewQueueGrid.SelectedItem -OriginGrid $script:Controls.ReviewQueueGrid }
    catch { Write-WorkbenchLog "Review selection preview failed: $($_.Exception.Message)" 'WARN' }
})
$script:Controls.DeploymentTypeQueueGrid.Add_SelectionChanged({
    try { Select-QueueItem -Item $script:Controls.DeploymentTypeQueueGrid.SelectedItem -OriginGrid $script:Controls.DeploymentTypeQueueGrid }
    catch { Write-WorkbenchLog "Deployment Type selection failed: $($_.Exception.Message)" 'WARN' }
})
$script:Controls.PreviousAppButton.Add_Click({
    $items=@($script:State.BatchItems); if($items.Count -eq 0){return}; $i=[array]::IndexOf($items,$script:State.CurrentQueueItem); if($i -gt 0){Select-QueueItem -Item $items[$i-1] -OriginGrid $null}
})
$script:Controls.NextAppButton.Add_Click({
    $items=@($script:State.BatchItems); if($items.Count -eq 0){return}; $i=[array]::IndexOf($items,$script:State.CurrentQueueItem); if($i -ge 0 -and $i -lt ($items.Count-1)){Select-QueueItem -Item $items[$i+1] -OriginGrid $null}
})
$script:Controls.ProcessBatchButton.Add_Click({
    try { Invoke-BatchIntake } catch { Write-WorkbenchLog $_.Exception.ToString() 'ERROR'; Show-ErrorDialog 'Batch intake failed' $_.Exception.Message }
})
$script:Controls.CancelBatchButton.Add_Click({
    $script:State.CancelAfterCurrent = $true
    $script:Controls.CancelBatchButton.IsEnabled = $false
    $script:Controls.CancelBatchButton.Content = 'Cancellation requested'
    $script:Controls.ProgressStageText.Text = 'Cancellation requested; the current application will finish or roll back safely.'
    Write-WorkbenchLog 'Operator requested cancellation after the current application.' 'WARN'
})

$script:Controls.ConnectButton.Add_Click({
    Set-ConnectionState -State Connecting
    try {
        Connect-MecmSite -SiteCode $script:Controls.SiteCodeText.Text.Trim() -ProviderServer $script:Controls.ProviderText.Text.Trim()
        Set-ConnectionState -State Connected -Detail $script:State.SiteCode
    }
    catch {
        $script:State.Connected = $false
        $script:State.SiteConnected = $false
        Set-ConnectionState -State Failed
        Write-WorkbenchLog "MECM connection failed: $($_.Exception.Message)" 'ERROR'
        Show-ErrorDialog 'MECM connection failed' $_.Exception.Message
        try { Update-Preview } catch {}
        return
    }

    # Each discovery query is isolated. A folder, DP, or collection query can fail without invalidating the site connection.
    Refresh-MecmTargets
    Refresh-BatchGrid
    try { Update-Preview } catch { Write-WorkbenchLog "Preview refresh warning: $($_.Exception.Message)" 'WARN' }
})

$script:Controls.BrowseSourceButton.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = 'Choose an existing content source folder.'
        if (Test-FileSystemPath -Path $script:Controls.SourceRootText.Text -PathType Container) {
            $dialog.SelectedPath = $script:Controls.SourceRootText.Text
        }
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:Controls.SourceRootText.Text = $dialog.SelectedPath
            Update-Preview
        }
    } catch {
        Write-WorkbenchLog $_.Exception.Message 'ERROR'
        Show-ErrorDialog 'Source folder selection failed' $_.Exception.Message
    }
})

$script:Controls.CreateSourceButton.Add_Click({
    try {
        Ensure-SourceRoot -Path $script:Controls.SourceRootText.Text.Trim()
    } catch {
        Write-WorkbenchLog $_.Exception.Message 'ERROR'
        Show-ErrorDialog 'Unable to create source path' $_.Exception.Message
        return
    }

    try {
        Update-Preview
    } catch {
        Write-WorkbenchLog "Source path is ready, but preview refresh failed: $($_.Exception.Message)" 'ERROR'
        Show-ErrorDialog 'Preview refresh failed' $_.Exception.Message
        return
    }

    [System.Windows.MessageBox]::Show('The content source root now exists.','Source path ready','OK','Information') | Out-Null
})

$script:Controls.CreateAppFolderButton.Add_Click({
    try {
        if (-not $script:State.Connected) { throw 'Connect to MECM before creating an Application folder.' }
        $requestedFolder = $script:Controls.FolderCombo.Text.Trim()
        if ([string]::IsNullOrWhiteSpace($requestedFolder)) { throw 'Enter a folder name or nested path, such as LAB\Utilities.' }
        $normalizedFolder = New-ApplicationFolderIfNeeded -FolderPath $requestedFolder
        Refresh-MecmTargets
        $script:Controls.FolderCombo.Text = $normalizedFolder
        Update-Preview
        [System.Windows.MessageBox]::Show("Application folder '$normalizedFolder' is ready.",'Application folder ready','OK','Information') | Out-Null
    }
    catch {
        Write-WorkbenchLog "Application folder creation failed: $($_.Exception.Message)" 'ERROR'
        Show-ErrorDialog 'Unable to create Application folder' $_.Exception.Message
    }
})

$script:Controls.DistributionModeCombo.Add_SelectionChanged({
    try { Refresh-DistributionTargets; Update-Preview } catch { Write-WorkbenchLog $_.Exception.Message 'WARN' }
})


function Sync-QueueDeploymentSettings {
    param([object]$Item)
    if (-not $Item) { return }
    if ($Item.DeploymentAction -eq 'Import only') {
        $Item.Collection = 'Not applicable'
    }
    elseif ($Item.DeploymentAction -eq 'Available' -and ([string]::IsNullOrWhiteSpace([string]$Item.Collection) -or $Item.Collection -eq 'Not applicable')) {
        if ($script:State.DeviceCollections.Count -gt 0) { $Item.Collection = $script:State.DeviceCollections[0] }
    }
    if ($script:State.CurrentQueueItem -eq $Item) { Select-QueueItem -Item $Item -OriginGrid $script:Controls.BatchGrid }
}

foreach ($grid in @($script:Controls.BatchGrid,$script:Controls.ReviewQueueGrid)) {
    $grid.Add_CurrentCellChanged({
        try {
            $item = $this.CurrentItem
            if ($item) { Sync-QueueDeploymentSettings -Item $item }
        } catch { Write-WorkbenchLog "Queue deployment edit warning: $($_.Exception.Message)" 'WARN' }
    })
    $grid.Add_BeginningEdit({
        param($sender,$eventArgs)
        try {
            if ($eventArgs.Column.Header -eq 'Collection' -and $eventArgs.Row.Item.DeploymentAction -ne 'Available') { $eventArgs.Cancel = $true }
        } catch {}
    })
}


$script:Controls.ResetCommandsButton.Add_Click({
    try {
        $item=$script:State.CurrentQueueItem
        if (-not $item -or -not $item.Metadata) { throw 'Select a valid queued installer first.' }
        $d=Get-DefaultInstallerCommands -Metadata $item.Metadata
        $script:Controls.InstallCommandText.Text=$d.Install; $script:Controls.UninstallCommandText.Text=$d.Uninstall
        Save-SelectedDeploymentTypeSettings; Update-Preview
    } catch { Show-ErrorDialog 'Unable to reset commands' $_.Exception.Message }
})
$script:Controls.DetectionTypeCombo.Add_SelectionChanged({ try { Update-DetectionEditorVisibility; Save-SelectedDeploymentTypeSettings; Update-Preview } catch {} })
$script:Controls.CommandApprovalCheck.Add_Checked({ try { Save-SelectedDeploymentTypeSettings; Update-CommandApprovalPanelVisual; Update-Preview } catch {} })
$script:Controls.CommandApprovalCheck.Add_Unchecked({ try { Save-SelectedDeploymentTypeSettings; Update-CommandApprovalPanelVisual; Update-Preview } catch {} })
foreach ($control in @($script:Controls.InstallCommandText,$script:Controls.UninstallCommandText,$script:Controls.DetectionPathText,$script:Controls.DetectionFileNameText,$script:Controls.RegistryKeyText,$script:Controls.RegistryValueNameText,$script:Controls.DetectionScriptText)) {
    $control.Add_LostFocus({ try { Save-SelectedDeploymentTypeSettings; Update-Preview } catch {} })
}
foreach ($control in @($script:Controls.InstallCommandText,$script:Controls.UninstallCommandText)) {
    $control.Add_TextChanged({
        try {
            if (-not $script:State.PreviewBusy -and $script:State.CurrentQueueItem -and [string]$script:State.CurrentQueueItem.InstallerType -eq 'EXE' -and [bool]$script:Controls.CommandApprovalCheck.IsChecked) {
                $script:Controls.CommandApprovalCheck.IsChecked = $false
            }
            Update-ExeReadinessGuidance
        } catch {}
    })
}
foreach ($control in @($script:Controls.DetectionPathText,$script:Controls.DetectionFileNameText,$script:Controls.RegistryKeyText,$script:Controls.RegistryValueNameText,$script:Controls.DetectionScriptText)) {
    $control.Add_TextChanged({ try { Update-ExeReadinessGuidance } catch {} })
}
$script:Controls.RegistryHiveCombo.Add_SelectionChanged({ try { Save-SelectedDeploymentTypeSettings; Update-Preview } catch {} })

$script:Controls.ValidateAllButton.Add_Click({
    try { Invoke-ValidateAll } catch { Write-WorkbenchLog $_.Exception.Message 'ERROR'; Show-ErrorDialog 'Validate All failed' $_.Exception.Message }
})

$script:Controls.ValidateButton.Add_Click({
    try { Update-Preview -FullValidation } catch { Write-WorkbenchLog $_.Exception.Message 'ERROR'; Show-ErrorDialog 'Validation failed' $_.Exception.Message }
})

$script:Controls.CreateButton.Add_Click({
    if (-not $script:State.LastValidationPassed -or $script:State.LastValidatedPath -ne $script:State.InstallerPath) {
        Show-ErrorDialog 'Validation required' 'Validate the currently selected package before creating it.'
        return
    }
    $answer = [System.Windows.MessageBox]::Show('Create the application, deployment type, content distribution, and deployment behavior exactly as shown in Preview?','Confirm application intake','YesNo','Warning')
    if ($answer -ne 'Yes') { return }
    try {
        $script:State.CurrentBatchTotal = 0
        Set-ProcessingUi -IsProcessing $true
        Invoke-CreateApplication
    } catch {
        Write-WorkbenchLog $_.Exception.ToString() 'ERROR'
        Invoke-ItemRollback
        $script:Controls.ResultText.Text = "FAILED`r`n`r`n$($_.Exception.Message)`r`n`r`nReview log: $script:LogFile"
        $script:Controls.Tabs.SelectedIndex = 4
        Show-ErrorDialog 'Application creation failed' $_.Exception.Message
    } finally { Set-ProcessingUi -IsProcessing $false }
})

foreach ($controlName in @('AdminNameText','LocalizedNameText','PublisherText','VersionText','DescriptionText','CommentsText','SourceRootText','AutoCreateSourceCheck','FolderCombo','DistributionModeCombo','DistributionTargetCombo')) {
    $control = $script:Controls[$controlName]
    if ($control -is [System.Windows.Controls.TextBox]) {
        $control.Add_TextChanged({ try { Update-Preview } catch {} })
    } elseif ($control -is [System.Windows.Controls.ComboBox]) {
        $control.Add_SelectionChanged({ try { Update-Preview } catch {} })
    } elseif ($control -is [System.Windows.Controls.CheckBox]) {
        $control.Add_Click({ try { Update-Preview } catch {} })
    }
}


foreach ($control in @($script:Controls.AdminNameText,$script:Controls.LocalizedNameText,$script:Controls.PublisherText,$script:Controls.VersionText,$script:Controls.DescriptionText,$script:Controls.CommentsText)) {
    $control.Add_LostFocus({ try { Save-CurrentQueueItemSettings; Refresh-BatchGrid } catch {} })
}

Refresh-BatchGrid
Set-ConnectionState -State Disconnected
Update-ActionAvailability
Write-WorkbenchLog "Started MECM Application Intake Workbench v$script:AppVersion" 'INFO'
$window.ShowDialog() | Out-Null
