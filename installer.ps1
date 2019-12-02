param(  [Parameter(Mandatory=$true)][String]$ComponentPath,
        [switch] $DetectOnly)

$ErrorActionPreference = “Stop”

enum LogLevel
{
    Info
    Debug
    Error
    Warn
}

function Log ($RunFolder, [LogLevel]$LogLevel, $Line)
{
    $LogFile = Join-Path -Path $RunFolder -ChildPath "PackageInstall.log"
    $Line = $LogLevel.ToString() + ":" + $Line
    $Line | Out-File -FilePath $LogFile -Append
    switch ($LogLevel) {
        Info    { Write-Verbose  -Message $Line -Verbose }
        Debug   { Write-Debug    -Message $Line }
        Error   { Write-Error    -Message $Line }
        Warn    { Write-Warning  -Message $Line }
    }
}

function Get-RunFolder($ComponentName)
{
    $Folder = "C:\.winstall\install\$ComponentName"
    if (Test-Path -Path $Folder) {
        Remove-Item -Path $Folder -Recurse -Force | Out-Null
    }
    New-Item -Path $Folder -ItemType Directory | Out-Null
    return $Folder
}

function Step-Download($XmlNode, $RunFolder)
{
    $FileName = $XmlNode.InnerText  | Split-Path -Leaf
    $Output = Join-Path -Path $RunFolder -ChildPath $FileName
    $WebClient = New-Object System.Net.WebClient
    Log -RunFolder $RunFolder -LogLevel Info -Line "Downloading:$($XmlNode.InnerText)"
    $WebClient.DownloadFile($XmlNode.InnerText, $Output)
    if (!(Test-Path -Path $Output)) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Failed to download $($XmlNode.InnerText) to $Output"
        return $False
    }
    return $True
}

function Step-CreateDir($XmlNode, $RunFolder)
{
    $FolderName = $XmlNode.InnerText
    if (Test-Path -Path $FolderName) {
       if ((Get-Item $FolderName) -is [System.IO.DirectoryInfo]) {
           return $true
       }
       Log -RunFolder $RunFolder -LogLevel Error -Line "$FolderName already exists and is not a folder"
       return $False
    }
    New-Item -Path $FolderName -ItemType Directory | Out-Null
    if (!(Test-Path -Path $FolderName)) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Failed to create $FolderName"
        return $False
    }
    return $True
}

function Step-CopyFile($XmlNode, $RunFolder)
{
    $SourceNode = $XmlNode.source
    if ($Null -eq $SourceNode) {
       Log -RunFolder $RunFolder -LogLevel Error -Line "source node is missing from copy_file step"
       return $False
    }

    $DestNode = $XmlNode.dest
    if ($Null -eq $DestNode) {
       Log -RunFolder $RunFolder -LogLevel Error -Line "dest node is missing from copy_file step"
       return $False
    }

    $SourcePath = Join-Path -Path $RunFolder -ChildPath $SourceNode
    $DestPath = $DestNode
    Copy-Item -Path $SourcePath -Destination $DestPath
    if (!(Test-Path -Path $DestPath)) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Failed to copy $SourcePath to $DestPath"
        return $False
    }
    return $True
}

function Step-Path($XmlNode, $RunFolder)
{
    $PathToAdd = $XmlNode.InnerText
    $PathKeyValue = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).path
    $AllPaths = $PathKeyValue.split(";")
    if ($AllPaths.Contains($PathToAdd)) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "System path variable already includes:$PathToAdd"
        return $True
    }
    $AllPaths += $PathToAdd
    $PathKeyValue = $AllPaths -join ';'
    Set-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH -Value $PathKeyValue -Force
    $PathKeyValue = (Get-ItemProperty -Path 'Registry::HKEY_LOCAL_MACHINE\System\CurrentControlSet\Control\Session Manager\Environment' -Name PATH).path
    if (!($PathKeyValue.Contains($PathToAdd))) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "Failed to add:$PathToAdd to System path variable"
        return $False
    }
    return $True
}

function Step-Command($XmlNode, $RunFolder)
{
    Push-Location -Path $RunFolder
    $command = $XmlNode.commandLine
    $args = @()
    foreach ($ArgNode in $XmlNode.args.arg) {
        $args += $ArgNode
    }
    $argString = $args -join " "
    Log -RunFolder $RunFolder -LogLevel Info -Line "Executing:$command $argString"
    $process = (Start-Process –PassThru -FilePath $command -ArgumentList $args -Wait)
    Pop-Location

    $process_exit_code = $process.ExitCode

    $exit_codes = $XmlNode.exit_codes
    if ($null -eq $exit_codes) {
        if ([Int32]$process_exit_code -ne [Int32]0) {
            Log -RunFolder $RunFolder -LogLevel Error -Line "Process returned non-permitted exit code:$process_exit_code"
            return $False
        }
        return $True
    }

    foreach ($exit_code in $exit_codes.exit_code) {
        if ([Int32]$process_exit_code -eq [Int32]$exit_code) {
            return $true
        }
    }

    Log -RunFolder $RunFolder -LogLevel Error -Line "Process returned non-permitted exit code:$process_exit_code"
    return $False
}

function Step-RegSet($XmlNode, $RunFolder)
{
    $RegKey = $XmlNode.key
    $RegValue = $XmlNode.value
    $RegValueName = $XmlNode.value_name

    switch ($XmlNode.value_type) {
        "REG_DWORD" { $Type = [Microsoft.Win32.RegistryValueKind]::DWord}
        "REG_SZ"    { $Type = [Microsoft.Win32.RegistryValueKind]::String}
        default     { return $false }
    }

    [Microsoft.Win32.Registry]::SetValue($RegKey,$RegValueName,$RegValue,$Type)

    return $True
}

function Step-Powershell($XmlNode, $RunFolder)
{
    $scriptBlock = $XmlNode.scriptblock
    if ($null -eq $scriptBlock) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "scriptblock node is missing from powershell step"
        exit 1
    }

    Invoke-Expression -Command $scriptBlock

    return $True
}

function Step-Unzip($XmlNode, $RunFolder)
{
    $zipfile = $XmlNode.zipfile
    if ($null -eq $zipfile) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "zipfile node is missing from unzip step"
        exit 1
    }

    $destination = $XmlNode.destination
    if ($null -eq $destination) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "destination node is missing from unzip step"
        exit 1
    }

    Expand-Archive -Path $zipfile -Destination $destination -Verbose

    return $True
}

function Step-KillProcess($XmlNode, $RunFolder)
{
    Get-Process -Name $XmlNode.InnerText | Stop-Process -Force -Verbose

    return $True
}

function Step-WaitProcess($XmlNode, $RunFolder)
{
    $Process = @(Get-Process -Name $XmlNode.InnerText -ErrorAction SilentlyContinue)

    while ($Process.Count -gt 0) {

        Log -RunFolder $RunFolder -LogLevel Info -Line "Waiting for process:$XmlNode"
        Start-Sleep -Seconds 1
        $Process = @(Get-Process -Name $XmlNode.InnerText -ErrorAction SilentlyContinue)
    }

    return $True
}

function Confirm-FileDetected($DetectionNode, $RunFolder)
{
    if (!(Test-Path -Path $DetectionNode.path)) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):$($DetectionNode.path) not found"
        return $False
    }

    if (!((Get-Item $DetectionNode.path) -is [System.IO.FileInfo])) {
        Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):$($DetectionNode.path) found but is not a file"
        return $False
    }

    $expectedVersion = $DetectionNode.version
    if ($null -ne $expectedVersion) {
        $foundVersion = (Get-Command $DetectionNode.path).Version
        if ($foundVersion -ne [version]$expectedVersion) {
            Log -RunFolder $RunFolder -LogLevel Info -Line "(Detection):$($DetectionNode.path) found but version is:$foundVersion (expected:$expectedVersion)"
            return $False
        }
    }

    return $True
}

function Confirm-PowershellDetected($DetectionNode, $RunFolder)
{
    $scriptBlock = $DetectionNode.scriptblock
    if ($null -eq $scriptBlock) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Powershell detection node missing scriptblock"
        exit 1
    }

    $expected = $DetectionNode.expected
    if ($null -eq $expected) {
        Log -RunFolder $RunFolder -LogLevel Error -Line "Powershell detection node missing expected"
        exit 1
    }

    $Result = Invoke-Expression -Command $scriptBlock

    return ($Result -eq $expected)
}

function Confirm-IsDetected($XmlNode, $RunFolder)
{
    foreach ($DetectionNode in $XmlNode.ChildNodes) {
        switch ($DetectionNode.LocalName) {
            "file"          { if (!(Confirm-FileDetected        -DetectionNode $DetectionNode -RunFolder $RunFolder)) {return $false} ; break}
            "powershell"    { if (!(Confirm-PowershellDetected  -DetectionNode $DetectionNode -RunFolder $RunFolder)) {return $false} ; break}
            default  {Log -RunFolder $RunFolder -LogLevel Warn -Line "Unknown detection step in XML $($DetectionNode.LocalName)"; exit 1}
        }
    }
    return $True
}

function Copy-FolderContents($SourcePath, $DestinationPath)
{
    $ChildItems = Get-ChildItem -Path $SourcePath -Recurse
    ForEach ($ChildItem in $ChildItems) {
        $Dest = $ChildItem.FullName.Substring($SourcePath.Length + 1)
        $Dest = Join-Path -Path $DestinationPath -ChildPath $Dest
        if ($ChildItem.PSIsContainer)
        {
            New-Item -Path $Dest -ItemType Directory -Verbose | Out-Null
        }
        else
        {
            Copy-Item -Path $ChildItem.FullName -Destination $Dest -Verbose
        }
    }
}

function Install-Component($ComponentPath, $DetectOnly)
{
    $ComponentName = Split-Path -Path $ComponentPath -Leaf

    if (!(Test-Path -Path $ComponentPath)) {
        Log -RunFolder $RunFolder -LogLevel Error  -Line "Failed to find $ComponentPath"
        return "Fail"
    }
    $ComponentXMLPath = Join-Path -Path $ComponentPath -ChildPath "install.xml"
    if (!(Test-Path -Path $ComponentXMLPath)) {
        Log -RunFolder $RunFolder -LogLevel Error  -Line "Failed to find $ComponentXMLPath"
        return "Fail"
    }
    [xml]$XmlDocument = Get-Content -Path $ComponentXMLPath
    if ($null -eq $XmlDocument) {
        Log -RunFolder $RunFolder -LogLevel Error  -Line "Failed to find parse $ComponentXMLPath"
        return "Fail"
    }

    $PackageNode = $XmlDocument.package
    if ($null -eq $PackageNode) {
        Log -RunFolder $RunFolder -LogLevel Error  -Line "Failed to find package node in $ComponentXMLPath"
        return "Fail"
    }

    $RunFolder = Get-RunFolder -ComponentName $ComponentName
    Log -RunFolder $RunFolder -LogLevel Info  -Line "Package:$ComponentName runfolder:$RunFolder"

    $DetectionNode = $PackageNode.detect
    if ($null -ne $DetectionNode ) {
        if (Confirm-IsDetected -XmlNode $DetectionNode -RunFolder $RunFolder) {
            Log -RunFolder $RunFolder -LogLevel Info  -Line "Package is detected:$ComponentName"
            return "AlreadyInstalled"
        }
        if ($DetectOnly) {
            Log -RunFolder $RunFolder -LogLevel Info  -Line "Package is not detected:$ComponentName"
            return "Fail"
        }
    }

    if ($DetectOnly) {
        return "Success"
    }

    $FilesPath = Join-Path -Path $ComponentPath -ChildPath "files"
    if (Test-Path -Path $FilesPath) {
        Copy-FolderContents -SourcePath $FilesPath -DestinationPath $RunFolder
    }

    Log -RunFolder $RunFolder -LogLevel Info  -Line "Installing package:$ComponentName"

    foreach ($StepNode in $PackageNode.steps.ChildNodes) {
        switch ($StepNode.LocalName) {
            "download"     { if (!(Step-Download    -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "create_dir"   { if (!(Step-CreateDir   -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "copy_file"    { if (!(Step-CopyFile    -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "path"         { if (!(Step-Path        -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "command"      { if (!(Step-Command     -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "reg_set"      { if (!(Step-RegSet      -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "powershell"   { if (!(Step-Powershell  -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "unzip"        { if (!(Step-Unzip       -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "kill_process" { if (!(Step-KillProcess -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            "wait_process" { if (!(Step-WaitProcess -XmlNode $StepNode -RunFolder $RunFolder)) {return "Fail"} ; break}
            default {Log -RunFolder $RunFolder -LogLevel Error -Line "Unknown step in XML $($StepNode.LocalName)"; break}
        }
    }

    $RebootNode = $PackageNode.reboot
    if ($null -ne $RebootNode) {
        Log -RunFolder $RunFolder -LogLevel Info  -Line "Reboot required $ComponentName"
        return "Reboot"
    }

    if ($null -ne $DetectionNode ) {
        if (!(Confirm-IsDetected -XmlNode $DetectionNode -RunFolder $RunFolder)) {
            Log -RunFolder $RunFolder -LogLevel Error  -Line "Package is not detected after install $ComponentName"
            return "Fail"
        }
        Log -RunFolder $RunFolder -LogLevel Info  -Line "Post install package is detected $ComponentName"
    }

    return "Success"
}


Install-Component -ComponentPath $ComponentPath -DetectOnly:$DetectOnly
